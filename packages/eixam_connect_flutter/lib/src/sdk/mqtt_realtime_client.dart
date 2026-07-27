import 'dart:async';
import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/interfaces/realtime_client.dart';
import 'package:flutter/foundation.dart';

import '../data/datasources_remote/sdk_session_context.dart';
import '../diagnostics/security_diagnostics_redactor.dart';
import '../device/ble_debug_registry.dart';
import 'mqtt_topic_segment.dart';
import 'operational_realtime_client.dart';
import 'sdk_mqtt_contract.dart';
import 'sdk_mqtt_transport.dart';

typedef SdkMqttTransportFactory = SdkMqttTransport Function(
  SdkMqttConnectRequest request,
);

class MqttRealtimeClient implements RealtimeClient, OperationalRealtimeClient {
  MqttRealtimeClient({
    required this.config,
    required this.sessionContext,
    required this.transportFactory,
    this.reconnectDelay = const Duration(seconds: 2),
    this.connectTimeout = const Duration(seconds: 8),
  }) {
    _connectionController.add(_state);
  }

  final EixamSdkConfig config;
  final SdkSessionContext sessionContext;
  final SdkMqttTransportFactory transportFactory;
  final Duration reconnectDelay;
  final Duration connectTimeout;

  final StreamController<RealtimeConnectionState> _connectionController =
      StreamController<RealtimeConnectionState>.broadcast();
  final StreamController<RealtimeEvent> _eventsController =
      StreamController<RealtimeEvent>.broadcast();

  RealtimeConnectionState _state = RealtimeConnectionState.disconnected;
  SdkMqttTransport? _transport;
  StreamSubscription<SdkMqttIncomingMessage>? _messageSub;
  StreamSubscription<SdkMqttDisconnectEvent>? _disconnectSub;
  Timer? _reconnectTimer;
  Future<void>? _connectFuture;
  bool _manualDisconnect = false;
  bool _disposed = false;
  EixamSession? _activeSession;
  Set<String> _subscribedTopics = <String>{};
  final Map<String, String> _diagnosticTransitions = <String, String>{};

  @override
  Future<void> connect() {
    _manualDisconnect = false;
    return _ensureConnected(initialConnect: true);
  }

  @override
  Future<void> disconnect() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _connectFuture = null;
    await _disconnectTransport();
    _setState(RealtimeConnectionState.disconnected);
  }

  @override
  Future<void> reconnectIfSessionChanged(EixamSession session) async {
    final previous = _activeSession;
    if (previous != null &&
        previous.appId == session.appId &&
        previous.externalUserId == session.externalUserId &&
        previous.userHash == session.userHash &&
        previous.sdkUserId == session.sdkUserId &&
        previous.canonicalExternalUserId == session.canonicalExternalUserId &&
        _state == RealtimeConnectionState.connected) {
      return;
    }

    await disconnect();
    _manualDisconnect = false;
    await _ensureConnected(initialConnect: true);
  }

  @override
  Future<void> publishOperationalSos(MqttOperationalSosRequest request) async {
    final session = sessionContext.currentSession;
    if (session == null) {
      throw const AuthException(
        'E_SDK_SESSION_REQUIRED',
        'E_SDK_SESSION_REQUIRED',
      );
    }
    final sdkUserId = MqttTopicSegment.usesLegacyUserTopics(session)
        ? ''
        : MqttTopicSegment.sdkUserIdFrom(session);
    final legacyUserId = MqttTopicSegment.usesLegacyUserTopics(session)
        ? MqttTopicSegment.legacyUserIdFrom(session)
        : null;

    await _ensureConnected(initialConnect: true);
    final transport = _transport;
    if (transport == null) {
      throw const NetworkException(
        'E_MQTT_NOT_CONNECTED',
        'The MQTT transport is not connected.',
      );
    }

    final envelope = SdkMqttContract.buildOperationalSosEnvelope(
      sdkUserId: sdkUserId,
      legacyUserId: legacyUserId,
      request: request,
    );
    final correlationId = _nextCorrelationId('sos');
    final payload = _decodeJsonObject(envelope.payload);
    final externalSos = _isExternalSosRequest(request, payload);
    if (externalSos) {
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS mqtt_publish_start '
        'triggerSource=${_field(payload, 'triggerSource', fallback: request.triggerSource ?? request.source ?? "none")} '
        'originatorNodeId=${request.originatorNodeId?.toString() ?? _intField(payload, 'originatorNodeId')?.toString() ?? "none"} '
        'relayNodeId=${request.relayNodeId?.toString() ?? _intField(payload, 'relayNodeId')?.toString() ?? "none"}',
      );
      try {
        await transport.publish(
          topic: envelope.topic,
          payload: envelope.payload,
          qos: SdkMqttQos.atLeastOnce,
          retain: false,
        );
        BleDebugRegistry.instance.recordEvent(
          'EXTERNAL_SOS mqtt_publish_result result=publish_returned '
          'topic=${envelope.topic} correlationId=$correlationId',
        );
      } catch (error) {
        BleDebugRegistry.instance.recordEvent(
          'EXTERNAL_SOS mqtt_publish_failed '
          'topic=${envelope.topic} correlationId=$correlationId '
          'errorType=${error.runtimeType} message=${_compactSummary(error)}',
        );
        rethrow;
      }
      return;
    }

    BleDebugRegistry.instance.recordEvent(
      '[BACKGROUND_SOS] mqtt_publish_method_entry '
      'deviceId=${request.deviceId ?? "none"} '
      'nodeId=${request.originatorNodeId?.toString() ?? "none"} '
      'hardwareId=${request.hardwareId ?? "none"} '
      'identitySource=${request.identitySource ?? "none"} '
      'incidentId=${request.incidentId ?? "none"}',
    );
    try {
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] mqtt_payload_built '
        'topic=${envelope.topic} correlationId=$correlationId '
        'deviceId=${_field(payload, 'deviceId')} '
        'nodeId=${_intField(payload, 'originatorNodeId')?.toString() ?? "none"} '
        'hardwareId=${_field(payload, 'hardwareId')} '
        'userId=${_field(payload, 'userId')} '
        'hasLocation=${payload.containsKey('latitude') && payload.containsKey('longitude')}',
      );
      BleDebugRegistry.instance.recordEvent(
        '[SOS_BACKEND_OUTBOUND_FINAL] transport=mqtt '
        'endpoint=${envelope.topic} correlationId=$correlationId '
        'source=${_field(payload, 'source', fallback: request.source ?? 'mqtt_operational_sos')} '
        'owner=${_intField(payload, 'originatorNodeId') == null ? "app" : "device"} '
        'deviceId=${_field(payload, 'deviceId')} '
        'nodeId=${_intField(payload, 'originatorNodeId')?.toString() ?? "none"} '
        'originatorNodeId=${_intField(payload, 'originatorNodeId')?.toString() ?? "none"} '
        'hardwareId=${_field(payload, 'hardwareId')} '
        'identitySource=${_field(payload, 'identitySource')} '
        'incidentId=${request.incidentId ?? "none"} '
        'canonicalIncidentId=none '
        'payload=${_redactedCompactJson(envelope.payload)}',
      );
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] mqtt_publish_start '
        'topic=${envelope.topic} correlationId=$correlationId qos=atLeastOnce',
      );
      await transport.publish(
        topic: envelope.topic,
        payload: envelope.payload,
        qos: SdkMqttQos.atLeastOnce,
        retain: false,
      );
      BleDebugRegistry.instance.recordEvent(
        '[SOS_BACKEND_RESPONSE] correlationId=$correlationId status=ok '
        'backendIncidentId=none responseSummary=mqtt_publish_accepted',
      );
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] mqtt_publish_result '
        'topic=${envelope.topic} correlationId=$correlationId '
        'result=publish_returned',
      );
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        '[SOS_BACKEND_RESPONSE] correlationId=$correlationId status=error '
        'backendIncidentId=none responseSummary=${_compactSummary(error)}',
      );
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] mqtt_publish_failed '
        'topic=${envelope.topic} correlationId=$correlationId '
        'errorType=${error.runtimeType} message=${_compactSummary(error)}',
      );
      rethrow;
    }
  }

  bool _isExternalSosRequest(
    MqttOperationalSosRequest request,
    Map<String, dynamic> payload,
  ) {
    final source = _field(
      payload,
      'source',
      fallback: request.source ?? request.triggerSource ?? 'unknown',
    );
    final triggerSource = _field(
      payload,
      'triggerSource',
      fallback: request.triggerSource ?? source,
    );
    final relaySource = _field(
      payload,
      'relaySource',
      fallback: request.relaySource ?? triggerSource,
    );
    return _normalizeOriginToken(source) == 'remote_lora_relay' ||
        _normalizeOriginToken(triggerSource) == 'remote_lora_relay' ||
        _normalizeOriginToken(relaySource) == 'remote_lora_relay';
  }

  String? _normalizeOriginToken(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed.toLowerCase().replaceAll('-', '_');
  }

  @override
  Future<void> publishTelemetry(SdkTelemetryPayload payload) async {
    final session = sessionContext.currentSession;
    if (session == null) {
      throw const AuthException(
        'E_SDK_SESSION_REQUIRED',
        'E_SDK_SESSION_REQUIRED',
      );
    }
    await _ensureConnected(initialConnect: true);
    final transport = _transport;
    if (transport == null) {
      throw const NetworkException(
        'E_MQTT_NOT_CONNECTED',
        'The MQTT transport is not connected.',
      );
    }

    final envelope = SdkMqttContract.buildTelemetryEnvelope(
      session: session,
      payload: payload.copyWith(userId: null),
    );
    final correlationId = _nextCorrelationId('tel');
    final envelopePayload = _decodeJsonObject(envelope.payload);
    BleDebugRegistry.instance.recordEvent(
      '[TELEMETRY_BACKEND_OUTBOUND_FINAL] transport=mqtt '
      'endpoint=${envelope.topic} correlationId=$correlationId '
      'source=${_field(envelopePayload, 'kind', fallback: 'mqtt_telemetry')} '
      'deviceId=${_field(envelopePayload, 'deviceId')} '
      'nodeId=${_intField(envelopePayload, 'nodeId')?.toString() ?? "none"} '
      'hardwareId=${_field(envelopePayload, 'hardwareId')} '
      'identitySource=${_field(envelopePayload, 'identitySource')} '
      'hasLocation=${envelopePayload.containsKey('latitude') && envelopePayload.containsKey('longitude')} '
      'timestamp=${_field(envelopePayload, 'timestamp')} '
      'payload=${_redactedCompactJson(envelope.payload)}',
    );
    BleDebugRegistry.instance.recordEvent(
      'Telemetry publish start -> transport=MQTT method=PUBLISH '
      'topic=${envelope.topic} payload=${_redactedCompactJson(envelope.payload)}',
    );
    try {
      await transport.publish(
        topic: envelope.topic,
        payload: envelope.payload,
        qos: SdkMqttQos.atLeastOnce,
        retain: false,
      );
      BleDebugRegistry.instance.recordEvent(
        'Telemetry publish success -> transport=MQTT topic=${envelope.topic} qos=1 retain=false backendHttpResponse=<not_applicable>',
      );
      BleDebugRegistry.instance.recordEvent(
        '[TELEMETRY_BACKEND_RESPONSE] correlationId=$correlationId status=ok '
        'responseSummary=mqtt_publish_accepted',
      );
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'Telemetry publish failure -> transport=MQTT topic=${envelope.topic} error=$error',
      );
      BleDebugRegistry.instance.recordEvent(
        '[TELEMETRY_BACKEND_RESPONSE] correlationId=$correlationId status=error '
        'responseSummary=${_compactSummary(error)}',
      );
      rethrow;
    }
  }

  @override
  Stream<RealtimeConnectionState> watchConnectionState() =>
      _connectionController.stream;

  @override
  Stream<RealtimeEvent> watchEvents() => _eventsController.stream;

  Future<void> dispose() async {
    _disposed = true;
    await disconnect();
    await _connectionController.close();
    await _eventsController.close();
  }

  Future<void> _ensureConnected({required bool initialConnect}) {
    final existing = _connectFuture;
    if (existing != null) {
      return existing;
    }

    if (_disposed) {
      return Future<void>.value();
    }

    final session = sessionContext.currentSession;
    if (session == null) {
      _activeSession = null;
      _setState(RealtimeConnectionState.disconnected);
      return Future<void>.value();
    }

    if (_state == RealtimeConnectionState.connected && _activeSession != null) {
      return Future<void>.value();
    }

    final completer = Completer<void>();
    final connectStopwatch = Stopwatch()..start();
    _connectFuture = completer.future;
    unawaited(() async {
      try {
        _logRealtime(
          'connect_start initial=$initialConnect '
          'session=${session.externalUserId} state=${_state.name}',
        );
        _setState(initialConnect
            ? RealtimeConnectionState.connecting
            : RealtimeConnectionState.reconnecting);
        await _connectTransport(session);
        _setState(RealtimeConnectionState.connected);
        _logRealtime('connect_success session=${session.externalUserId}');
        completer.complete();
      } catch (error) {
        _recordRealtime(
          'SDK_CLIENT_CREATION_TIMEOUT_GUARD '
          'step=mqtt_connect elapsedMs=${connectStopwatch.elapsedMilliseconds} '
          'errorType=${error.runtimeType}',
        );
        _logRealtime('connect_failure error=$error');
        await _disconnectTransport();
        _setState(RealtimeConnectionState.error);
        _scheduleReconnect();
        completer.complete();
      } finally {
        _connectFuture = null;
      }
    }());
    return completer.future;
  }

  Future<void> _connectTransport(EixamSession session) async {
    await _disconnectTransport();

    final request = SdkMqttContract.connectRequest(
      config: config,
      session: session,
    );
    final transport = transportFactory(request);
    _transport = transport;
    _activeSession = session;
    _subscribedTopics = SdkMqttTopics.eventTopicsFor(session);

    _messageSub = transport.watchMessages().listen((message) {
      final topicCategory = _sosEventTopicCategory(message.topic, session);
      final shape = _mqttPayloadShape(message.payload);
      _recordRealtime(
        'SOS_MQTT_EVENT_RECEIVED topicCategory=$topicCategory '
        'eventType=${shape.eventType} '
        'canonicalIncidentIdPresent=${shape.canonicalIncidentIdPresent} '
        'snapshotVersionPresent=${shape.snapshotVersionPresent} '
        'payloadShapeVersion=${shape.payloadShapeVersion}',
      );
      try {
        final parsed = SdkMqttContract.parseRealtimeEvent(
          topic: message.topic,
          payload: message.payload,
        );
        if (parsed.type == 'mqtt.message') {
          _recordRealtime(
            'SOS_MQTT_EVENT_PARSE_REJECTED reason=invalid_json_or_shape '
            'topicCategory=$topicCategory',
          );
          return;
        }
        final event = RealtimeEvent(
          type: parsed.type,
          timestamp: parsed.timestamp,
          payload: <String, dynamic>{
            ...?parsed.payload,
            '_mqttAuthenticatedUserScoped':
                _subscribedTopics.contains(message.topic) &&
                    _mqttPayloadIdentityMatches(
                      shape.payloadUserId,
                      topicCategory,
                      session,
                    ),
            '_mqttTopicCategory': topicCategory,
            '_mqttPayloadShapeVersion': shape.payloadShapeVersion,
          },
        );
        _recordRealtime(
          'SOS_MQTT_EVENT_PARSED topicCategory=$topicCategory '
          'eventType=${event.type} '
          'canonicalIncidentIdPresent=${shape.canonicalIncidentIdPresent} '
          'snapshotVersionPresent=${shape.snapshotVersionPresent}',
        );
        if (!_eventsController.isClosed) {
          _eventsController.add(event);
        }
      } catch (error) {
        _recordRealtime(
          'SOS_MQTT_EVENT_PARSE_REJECTED reason=parser_exception '
          'topicCategory=$topicCategory errorType=${error.runtimeType}',
        );
      }
    }, onError: (Object error, StackTrace stackTrace) {
      _recordRealtime(
        'MQTT_TRANSPORT_DISCONNECT_HANDLED '
        'phase=realtime_message_stream errorType=${error.runtimeType}',
      );
      _setState(RealtimeConnectionState.reconnecting);
      _scheduleReconnect();
    });
    _disconnectSub = transport.watchDisconnects().listen((event) {
      if (_manualDisconnect || _disposed || event.solicited) {
        _logRealtime(
          'disconnect solicited=${event.solicited} manual=$_manualDisconnect',
        );
        _setState(RealtimeConnectionState.disconnected);
        return;
      }
      _logRealtime('disconnect unexpected reconnect_scheduled=true');
      _setState(RealtimeConnectionState.reconnecting);
      _scheduleReconnect();
    }, onError: (Object error, StackTrace stackTrace) {
      _recordRealtime(
        'MQTT_TRANSPORT_DISCONNECT_HANDLED '
        'phase=realtime_disconnect_stream errorType=${error.runtimeType}',
      );
      _setState(RealtimeConnectionState.reconnecting);
      _scheduleReconnect();
    });

    await transport.connect().timeout(connectTimeout);
    for (final topic in _subscribedTopics) {
      final category = _sosEventTopicCategory(topic, session);
      _recordRealtimeTransition(
        'SOS_MQTT_EVENT_SUBSCRIPTION_REQUESTED topicCategory=$category',
        key: 'subscription_request_$category',
        state: 'requested',
      );
      try {
        await transport.subscribe(topic);
        _recordRealtimeTransition(
          'SOS_MQTT_EVENT_SUBSCRIPTION_ACTIVE topicCategory=$category qos=1',
          key: 'subscription_active_$category',
          state: 'active',
        );
      } catch (error) {
        _diagnosticTransitions['subscription_request_$category'] = 'failed';
        _diagnosticTransitions['subscription_active_$category'] = 'failed';
        _recordRealtimeTransition(
          'SOS_MQTT_EVENT_SUBSCRIPTION_FAILED topicCategory=$category '
          'errorType=${error.runtimeType}',
          key: 'subscription_failure_$category',
          state: 'failed_${error.runtimeType}',
          failure: true,
        );
        rethrow;
      }
    }
    _recordRealtimeTransition(
      'SOS_MQTT_SOS_READY publishReady=true eventReady=true '
      'subscriptions=${_subscribedTopics.length}',
      key: 'sos_ready',
      state: 'ready_${_subscribedTopics.length}',
    );
  }

  Future<void> _disconnectTransport() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _messageSub?.cancel();
    await _disconnectSub?.cancel();
    _messageSub = null;
    _disconnectSub = null;
    final transport = _transport;
    _transport = null;
    await transport?.disconnect();
    await transport?.dispose();
  }

  void _scheduleReconnect() {
    if (_manualDisconnect || _disposed || _reconnectTimer != null) {
      return;
    }
    if (sessionContext.currentSession == null) {
      return;
    }
    _recordRealtime(
      'MQTT_TRANSPORT_RECONNECT_SCHEDULED '
      'delayMs=${reconnectDelay.inMilliseconds}',
    );
    _reconnectTimer = Timer(reconnectDelay, () {
      _reconnectTimer = null;
      unawaited(_ensureConnected(initialConnect: false));
    });
  }

  void _setState(RealtimeConnectionState next) {
    if (_state == next) {
      return;
    }
    _logRealtime('state ${_state.name}->${next.name}');
    _state = next;
    if (!_connectionController.isClosed) {
      _connectionController.add(next);
    }
  }

  void _logRealtime(String message) {
    if (!config.enableLogging) {
      return;
    }
  }

  void _recordRealtime(String message) {
    BleDebugRegistry.instance.recordEvent(message);
  }

  void _recordRealtimeTransition(
    String message, {
    required String key,
    required String state,
    bool failure = false,
  }) {
    final previous = _diagnosticTransitions[key];
    if (!failure && previous == state) {
      return;
    }
    _diagnosticTransitions[key] = state;
    _recordRealtime(message);
  }

  String _nextCorrelationId(String prefix) =>
      '$prefix-${DateTime.now().toUtc().microsecondsSinceEpoch}';

  Map<String, dynamic> _decodeJsonObject(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      // Keep logging resilient; the raw payload is still summarized below.
    }
    return const <String, dynamic>{};
  }

  String _field(
    Map<String, dynamic> payload,
    String key, {
    String fallback = 'none',
  }) {
    final value = payload[key];
    if (value == null) {
      return fallback;
    }
    final text = value.toString().trim();
    return text.isEmpty ? fallback : text;
  }

  int? _intField(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    if (value is int) {
      return value;
    }
    if (value is String) {
      return int.tryParse(value.trim());
    }
    return null;
  }

  String _redactedCompactJson(String payload) {
    return SecurityDiagnosticsRedactor.compactJsonForDiagnostics(
      payload,
      allowSensitive: kDebugMode,
    );
  }

  String _compactSummary(Object? value) {
    return SecurityDiagnosticsRedactor.compactSummary(value, maxLength: 240);
  }

  String _sosEventTopicCategory(String topic, EixamSession session) {
    if (MqttTopicSegment.usesLegacyUserTopics(session)) {
      final legacyOnlyTopic =
          'sos/events/${MqttTopicSegment.encode(MqttTopicSegment.legacyUserIdFrom(session))}';
      return topic == legacyOnlyTopic ? 'legacy_alias' : 'other';
    }
    final internalTopic =
        'sos/events/${MqttTopicSegment.encode(MqttTopicSegment.sdkUserIdFrom(session))}';
    if (topic == internalTopic) {
      return 'internal';
    }
    final legacyTopic =
        'sos/events/${MqttTopicSegment.encode(MqttTopicSegment.legacyUserIdFrom(session))}';
    if (topic == legacyTopic) {
      return 'legacy_alias';
    }
    return 'other';
  }

  _MqttPayloadShape _mqttPayloadShape(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        final eventType = decoded['type']?.toString().trim();
        final incident = decoded['incident'];
        final nested = incident is Map ? incident : const <String, dynamic>{};
        final incidentId =
            decoded['incidentId'] ?? decoded['id'] ?? nested['id'];
        final snapshotVersion = decoded['snapshotVersion'] ??
            decoded['snapshot_version'] ??
            (decoded['actuators'] is Map
                ? (decoded['actuators'] as Map)['snapshotVersion']
                : null);
        final shapeVersion = decoded['schemaVersion'] ??
            decoded['schema_version'] ??
            decoded['version'] ??
            'legacy';
        return _MqttPayloadShape(
          eventType: eventType == null || eventType.isEmpty
              ? 'unknown'
              : eventType.toLowerCase(),
          canonicalIncidentIdPresent:
              incidentId is String && incidentId.trim().isNotEmpty,
          snapshotVersionPresent: snapshotVersion != null,
          payloadShapeVersion: shapeVersion.toString(),
          payloadUserId: decoded['userId']?.toString().trim(),
        );
      }
    } catch (_) {
      // The parser boundary reports the rejection without exposing payload.
    }
    return const _MqttPayloadShape(
      eventType: 'unknown',
      canonicalIncidentIdPresent: false,
      snapshotVersionPresent: false,
      payloadShapeVersion: 'invalid',
      payloadUserId: null,
    );
  }

  bool _mqttPayloadIdentityMatches(
    String? payloadUserId,
    String topicCategory,
    EixamSession session,
  ) {
    final normalized = payloadUserId?.trim();
    if (normalized == null || normalized.isEmpty) {
      return false;
    }
    if (topicCategory == 'internal' &&
        !MqttTopicSegment.usesLegacyUserTopics(session)) {
      return normalized == MqttTopicSegment.sdkUserIdFrom(session);
    }
    if (topicCategory == 'legacy_alias') {
      return normalized == MqttTopicSegment.legacyUserIdFrom(session);
    }
    return false;
  }
}

class _MqttPayloadShape {
  const _MqttPayloadShape({
    required this.eventType,
    required this.canonicalIncidentIdPresent,
    required this.snapshotVersionPresent,
    required this.payloadShapeVersion,
    required this.payloadUserId,
  });

  final String eventType;
  final bool canonicalIncidentIdPresent;
  final bool snapshotVersionPresent;
  final String payloadShapeVersion;
  final String? payloadUserId;
}
