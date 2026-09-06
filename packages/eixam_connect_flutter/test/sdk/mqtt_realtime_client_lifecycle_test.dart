import 'dart:async';
import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/sdk/mqtt_realtime_client.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_contract.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sessionA = EixamSession(
    appId: 'commercial-app',
    externalUserId: 'external-a',
    canonicalExternalUserId: 'external-a',
    sdkUserId: 'internal-a',
    userHash: 'test-signature-a',
  );
  const sessionB = EixamSession(
    appId: 'commercial-app',
    externalUserId: 'external-b',
    canonicalExternalUserId: 'external-b',
    sdkUserId: 'internal-b',
    userHash: 'test-signature-b',
  );

  late SdkSessionContext sessionContext;
  late List<_ControlledMqttTransport> queuedTransports;
  late List<_ControlledMqttTransport> createdTransports;
  late MqttRealtimeClient client;
  late StreamSubscription<RealtimeConnectionState> stateSubscription;
  late List<RealtimeConnectionState> states;

  void createClient({
    Duration reconnectDelay = const Duration(hours: 1),
    Duration connectTimeout = const Duration(seconds: 8),
  }) {
    client = MqttRealtimeClient(
      config: const EixamSdkConfig(
        apiBaseUrl: 'https://api.staging.eixam.io',
        websocketUrl: 'ssl://mqtt.staging.eixam.io:8883',
      ),
      sessionContext: sessionContext,
      transportFactory: (request) {
        final transport = queuedTransports.removeAt(0)..request = request;
        createdTransports.add(transport);
        return transport;
      },
      reconnectDelay: reconnectDelay,
      connectTimeout: connectTimeout,
    );
    states = <RealtimeConnectionState>[];
    stateSubscription = client.watchConnectionState().listen(states.add);
  }

  setUp(() async {
    await BleDebugRegistry.instance.resetForLifecycle();
    sessionContext = SdkSessionContext()..currentSession = sessionA;
    queuedTransports = <_ControlledMqttTransport>[];
    createdTransports = <_ControlledMqttTransport>[];
  });

  tearDown(() async {
    await client.dispose();
    await stateSubscription.cancel();
  });

  test('disconnect invalidates an in-flight connection without closing it',
      () async {
    final transportA = _ControlledMqttTransport();
    queuedTransports.add(transportA);
    createClient();

    final connectA = client.connect();
    await transportA.connectStarted.future;
    await client.disconnect();

    expect(transportA.disconnectCalls, 0);
    expect(states, isNot(contains(RealtimeConnectionState.connected)));

    transportA.succeedConnect();
    await connectA;
    await transportA.disposeCompleted.future;

    expect(states, isNot(contains(RealtimeConnectionState.connected)));
    expect(transportA.disconnectCalls, 1);
    expect(_hasDiagnostic('event=stale_connect_discarded'), isTrue);
  });

  test('late connection A cannot replace or dispose authoritative connection B',
      () async {
    final transportA = _ControlledMqttTransport();
    final transportB = _ControlledMqttTransport();
    queuedTransports.addAll(<_ControlledMqttTransport>[transportA, transportB]);
    createClient();

    final connectA = client.connect();
    await transportA.connectStarted.future;
    await client.disconnect();

    final connectB = client.connect();
    await transportB.connectStarted.future;
    transportA.succeedConnect();
    await connectA;
    await transportA.disposeCompleted.future;

    expect(transportB.disconnectCalls, 0);
    expect(transportB.disposeCalls, 0);
    expect(states, isNot(contains(RealtimeConnectionState.connected)));

    transportB.succeedConnect();
    await connectB;
    await _drainStreamEvents();

    expect(states.last, RealtimeConnectionState.connected);
    expect(transportB.disconnectCalls, 0);
    expect(transportB.disposeCalls, 0);
  });

  test('session replacement invalidates the previous in-flight generation',
      () async {
    final transportA = _ControlledMqttTransport();
    final transportB = _ControlledMqttTransport();
    queuedTransports.addAll(<_ControlledMqttTransport>[transportA, transportB]);
    createClient();

    final connectA = client.connect();
    await transportA.connectStarted.future;
    sessionContext.currentSession = sessionB;
    final replaceWithB = client.reconnectIfSessionChanged(sessionB);
    await transportB.connectStarted.future;

    transportA.succeedConnect();
    await connectA;
    await transportA.disposeCompleted.future;
    transportB.succeedConnect();
    await replaceWithB;
    await _drainStreamEvents();

    expect(transportA.subscriptions, isEmpty);
    expect(
      transportB.subscriptions,
      containsAll(<String>[
        'sos/events/${sessionB.sdkUserId}',
        'sos/events/${sessionB.externalUserId}',
      ]),
    );
    expect(transportB.request.username, contains(sessionB.externalUserId));
    expect(states.last, RealtimeConnectionState.connected);
  });

  test('reconnect attempt in progress is invalidated by teardown', () async {
    final transportA = _ControlledMqttTransport()..succeedConnect();
    final transportB = _ControlledMqttTransport();
    queuedTransports.addAll(<_ControlledMqttTransport>[transportA, transportB]);
    createClient(reconnectDelay: Duration.zero);
    await client.connect();

    transportA.emitUnexpectedDisconnect();
    await transportB.connectStarted.future;
    await client.disconnect();
    transportB.succeedConnect();
    await transportB.disposeCompleted.future;

    expect(createdTransports, hasLength(2));
    expect(states.last, RealtimeConnectionState.disconnected);
    expect(transportB.subscriptions, isEmpty);
  });

  test('disconnect event during teardown cannot schedule another transport',
      () async {
    final transport = _ControlledMqttTransport(
      blockDisconnect: true,
    )..succeedConnect();
    queuedTransports.add(transport);
    createClient(reconnectDelay: Duration.zero);
    await client.connect();

    final disconnect = client.disconnect();
    await transport.disconnectStarted.future;
    transport.emitUnexpectedDisconnect();
    await _drainStreamEvents();

    expect(createdTransports, hasLength(1));
    transport.finishDisconnect();
    await disconnect;
    await _drainStreamEvents();

    expect(createdTransports, hasLength(1));
    expect(states.last, RealtimeConnectionState.disconnected);
  });

  test('hung connect times out so SOS publish fails instead of blocking',
      () async {
    final first = _ControlledMqttTransport();
    final retry = _ControlledMqttTransport();
    queuedTransports.addAll(<_ControlledMqttTransport>[first, retry]);
    createClient(connectTimeout: const Duration(milliseconds: 80));

    final published = client.publishOperationalSos(
      MqttOperationalSosRequest(
        timestamp: DateTime.utc(2026, 9, 6, 12),
        triggerSource: 'commercial_app',
      ),
    );
    await first.connectStarted.future;

    await expectLater(published, throwsA(isA<NetworkException>()));
    await _drainStreamEvents();

    expect(states.last, RealtimeConnectionState.error);
    expect(_hasDiagnostic('event=connect_failed'), isTrue);
    expect(_hasDiagnostic('event=sos_publish_reconnect_after_connect_failure'),
        isTrue);
    expect(first.publishCalls, 0);
    expect(retry.publishCalls, 0);
  });

  test('async socket failure is contained and a fresh reconnect succeeds',
      () async {
    final transportA = _ControlledMqttTransport();
    final transportB = _ControlledMqttTransport();
    queuedTransports.addAll(<_ControlledMqttTransport>[transportA, transportB]);
    createClient();

    final connectA = client.connect();
    await transportA.connectStarted.future;
    scheduleMicrotask(() {
      transportA.failConnect(
        const SocketException('Bad file descriptor', port: 50525),
      );
    });
    await connectA;
    await _drainStreamEvents();

    expect(states.last, RealtimeConnectionState.error);
    expect(_hasDiagnostic('event=connect_failed'), isTrue);

    final connectB = client.connect();
    await transportB.connectStarted.future;
    transportB.succeedConnect();
    await connectB;
    await _drainStreamEvents();

    expect(states.last, RealtimeConnectionState.connected);
    expect(transportB.subscriptions, hasLength(2));
  });

  test('disconnect remains idempotent while transport teardown is pending',
      () async {
    final transport = _ControlledMqttTransport(
      blockDisconnect: true,
    )..succeedConnect();
    queuedTransports.add(transport);
    createClient();
    await client.connect();

    final firstDisconnect = client.disconnect();
    await transport.disconnectStarted.future;
    final secondDisconnect = client.disconnect();
    await secondDisconnect;

    expect(transport.disconnectCalls, 1);
    transport.finishDisconnect();
    await firstDisconnect;

    expect(states.last, RealtimeConnectionState.disconnected);
    expect(transport.disconnectCalls, 1);
    expect(transport.disposeCalls, 1);
  });
}

bool _hasDiagnostic(String token) {
  return BleDebugRegistry.instance.currentState.events.any(
    (event) => event.message.contains(token),
  );
}

Future<void> _drainStreamEvents() => Future<void>.delayed(Duration.zero);

final class _ControlledMqttTransport implements SdkMqttTransport {
  _ControlledMqttTransport({this.blockDisconnect = false});

  final bool blockDisconnect;
  final Completer<void> connectStarted = Completer<void>();
  final Completer<void> disconnectStarted = Completer<void>();
  final Completer<void> disposeCompleted = Completer<void>();
  final Completer<void> _connectResult = Completer<void>();
  final Completer<void> _disconnectResult = Completer<void>();
  final StreamController<SdkMqttIncomingMessage> _messages =
      StreamController<SdkMqttIncomingMessage>.broadcast();
  final StreamController<SdkMqttDisconnectEvent> _disconnects =
      StreamController<SdkMqttDisconnectEvent>.broadcast();
  final List<String> subscriptions = <String>[];

  late SdkMqttConnectRequest request;
  int disconnectCalls = 0;
  int disposeCalls = 0;
  int publishCalls = 0;
  bool _disposed = false;

  @override
  Future<void> connect() {
    if (!connectStarted.isCompleted) {
      connectStarted.complete();
    }
    return _connectResult.future;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls += 1;
    if (!disconnectStarted.isCompleted) {
      disconnectStarted.complete();
    }
    if (blockDisconnect) {
      await _disconnectResult.future;
    }
  }

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _messages.close();
    await _disconnects.close();
    if (!disposeCompleted.isCompleted) {
      disposeCompleted.complete();
    }
  }

  void emitUnexpectedDisconnect() {
    _disconnects.add(const SdkMqttDisconnectEvent(solicited: false));
  }

  void failConnect(Object error) {
    _connectResult.completeError(error);
  }

  void finishDisconnect() {
    if (!_disconnectResult.isCompleted) {
      _disconnectResult.complete();
    }
  }

  @override
  Future<void> publish({
    required String topic,
    required String payload,
    SdkMqttQos qos = SdkMqttQos.atLeastOnce,
    bool retain = false,
  }) async {
    publishCalls += 1;
  }

  @override
  Future<void> subscribe(String topic) async {
    subscriptions.add(topic);
  }

  void succeedConnect() {
    if (!_connectResult.isCompleted) {
      _connectResult.complete();
    }
  }

  @override
  Stream<SdkMqttDisconnectEvent> watchDisconnects() => _disconnects.stream;

  @override
  Stream<SdkMqttIncomingMessage> watchMessages() => _messages.stream;
}
