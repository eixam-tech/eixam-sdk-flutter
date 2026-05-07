import 'dart:async';
import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';
import 'package:eixam_connect_core/src/interfaces/realtime_client.dart';
import 'package:flutter/foundation.dart';

import '../data/datasources_remote/sdk_session_context.dart';
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
  }) {
    _connectionController.add(_state);
  }

  final EixamSdkConfig config;
  final SdkSessionContext sessionContext;
  final SdkMqttTransportFactory transportFactory;
  final Duration reconnectDelay;

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
        'A signed SDK session must be configured before publishing SOS over MQTT.',
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

    BleDebugRegistry.instance.recordEvent(
      '[BACKGROUND_SOS] mqtt_publish_method_entry '
      'deviceId=${request.deviceId ?? "none"} '
      'nodeId=${request.originatorNodeId?.toString() ?? "none"} '
      'hardwareId=${request.hardwareId ?? "none"} '
      'appDeviceId=${request.appDeviceId ?? "none"} '
      'identitySource=${request.identitySource ?? "none"} '
      'incidentId=${request.incidentId ?? "none"}',
    );
    try {
      final session = sessionContext.currentSession;
      if (session == null) {
        throw const AuthException(
          'E_SDK_SESSION_REQUIRED',
          'A signed SDK session must be configured before publishing SOS over MQTT.',
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

      final envelope = SdkMqttContract.buildOperationalSosEnvelope(
        request.copyWith(
          sdkUserId: session.canonicalExternalUserId ?? session.sdkUserId,
        ),
      );
      topic = envelope.topic;
      correlationId = _nextCorrelationId('sos');
      final payload = _decodeJsonObject(envelope.payload);
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] mqtt_payload_built '
        'topic=${envelope.topic} correlationId=$correlationId '
        'deviceId=${_field(payload, 'deviceId')} '
        'isLocalDeviceId=${_field(payload, 'deviceId').startsWith('app-device-local-')} '
        'nodeId=${_intField(payload, 'originatorNodeId')?.toString() ?? "none"} '
        'hardwareId=${_field(payload, 'hardwareId')} '
        'appDeviceId=${_field(payload, 'appDeviceId')} '
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
        'appDeviceId=${_field(payload, 'appDeviceId')} '
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
        'topic=$topic correlationId=$correlationId '
        'errorType=${error.runtimeType} message=${_compactSummary(error)}',
      );
      rethrow;
    } finally {
      methodStopwatch.stop();
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] mqtt_publish_finally '
        'topic=$topic correlationId=$correlationId '
        'elapsedMs=${methodStopwatch.elapsedMilliseconds}',
      );
    }
  }

  @override
  Future<void> publishTelemetry(SdkTelemetryPayload payload) async {
    final session = sessionContext.currentSession;
    if (session == null) {
      throw const AuthException(
        'E_SDK_SESSION_REQUIRED',
        'A signed SDK session must be configured before publishing telemetry over MQTT.',
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
      'appDeviceId=${_field(envelopePayload, 'appDeviceId')} '
      'hardwareId=${_field(envelopePayload, 'hardwareId')} '
      'identitySource=${_field(envelopePayload, 'identitySource')} '
      'lat=${_field(envelopePayload, 'latitude')} '
      'lon=${_field(envelopePayload, 'longitude')} '
      'timestamp=${_field(envelopePayload, 'timestamp')} '
      'payload=${_redactedCompactJson(envelope.payload)}',
    );
    BleDebugRegistry.instance.recordEvent(
      'Telemetry publish start -> transport=MQTT method=PUBLISH topic=${envelope.topic} payload=${envelope.payload}',
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
        _logRealtime('connect_failure error=$error');
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
      final event = SdkMqttContract.parseRealtimeEvent(
        topic: message.topic,
        payload: message.payload,
      );
      _eventsController.add(event);
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
    });

    await transport.connect();
    for (final topic in _subscribedTopics) {
      await transport.subscribe(topic);
    }
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
    _connectionController.add(next);
  }

  void _logRealtime(String message) {
    if (!config.enableLogging) {
      return;
    }
    debugPrint('[SDK_MQTT_REALTIME] $message');
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
    try {
      return jsonEncode(_redactJsonValue(jsonDecode(payload)));
    } catch (_) {
      return _compactSummary(payload);
    }
  }

  Object? _redactJsonValue(Object? value, {String? key}) {
    final normalizedKey = key?.toLowerCase();
    if (normalizedKey != null &&
        (normalizedKey.contains('token') ||
            normalizedKey.contains('secret') ||
            normalizedKey.contains('authorization') ||
            normalizedKey == 'password' ||
            normalizedKey == 'userhash' ||
            normalizedKey == 'email')) {
      return '<redacted>';
    }
    if (normalizedKey == 'userid' && value is String && value.contains('@')) {
      return '<redacted-email>';
    }
    if (value is Map) {
      return value.map<String, Object?>(
        (key, child) => MapEntry(
          key.toString(),
          _redactJsonValue(child, key: key.toString()),
        ),
      );
    }
    if (value is List) {
      return value.map((child) => _redactJsonValue(child)).toList();
    }
    return value;
  }

  String _compactSummary(Object? value) {
    final summary = value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (summary.isEmpty) {
      return 'none';
    }
    return summary.length <= 240 ? summary : '${summary.substring(0, 240)}...';
  }
}
