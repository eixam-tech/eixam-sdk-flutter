import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';
import 'package:eixam_connect_core/src/interfaces/realtime_client.dart';

import '../data/datasources_remote/sdk_session_context.dart';
import '../device/ble_debug_registry.dart';
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
    await transport.publish(
      topic: envelope.topic,
      payload: envelope.payload,
      qos: SdkMqttQos.atLeastOnce,
      retain: false,
    );
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
      payload: payload.copyWith(
        userId: payload.userId ??
            session.canonicalExternalUserId ??
            session.sdkUserId ??
            session.externalUserId,
      ),
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
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'Telemetry publish failure -> transport=MQTT topic=${envelope.topic} error=$error',
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
        _setState(initialConnect
            ? RealtimeConnectionState.connecting
            : RealtimeConnectionState.reconnecting);
        await _connectTransport(session);
        _setState(RealtimeConnectionState.connected);
        completer.complete();
      } catch (error) {
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
        _setState(RealtimeConnectionState.disconnected);
        return;
      }
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
    _state = next;
    _connectionController.add(next);
  }
}
