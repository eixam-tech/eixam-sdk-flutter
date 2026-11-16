import 'dart:async';
import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/diagnostics/sdk_release_log.dart';
import 'package:eixam_connect_flutter/src/sdk/mqtt_realtime_client.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_contract.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// SOS publishes connect on demand, never reuse a link the broker may have
/// expired (ACL session TTL), retry once on a fresh connection and fail
/// loudly instead of "publish returned" without a PUBACK.
void main() {
  const sdkUserId = '1641f888-49aa-458f-9a32-ecbac516f44e';
  const session = EixamSession(
    appId: 'commercial-app',
    externalUserId: 'a475f91b-02e7-4092-b13a-d8e882ed9b50',
    canonicalExternalUserId: 'a475f91b-02e7-4092-b13a-d8e882ed9b50',
    sdkUserId: sdkUserId,
    userHash: 'not-a-real-secret',
  );

  late List<_Transport> transports;
  late DateTime now;
  late int failNextPublishes;
  late MqttRealtimeClient client;

  setUp(() async {
    await BleDebugRegistry.instance.resetForLifecycle();
    sdkReleaseLogSinkForTesting = (_) {};
    transports = <_Transport>[];
    now = DateTime.utc(2026, 11, 10, 13);
    failNextPublishes = 0;
    client = MqttRealtimeClient(
      config: const EixamSdkConfig(
        apiBaseUrl: 'https://api.example.test',
        websocketUrl: 'wss://mqtt.example.test/mqtt',
      ),
      sessionContext: SdkSessionContext()..currentSession = session,
      transportFactory: (_) {
        final transport = _Transport(
          shouldFailPublish: () {
            if (failNextPublishes == 0) return false;
            failNextPublishes--;
            return true;
          },
        );
        transports.add(transport);
        return transport;
      },
      reconnectDelay: const Duration(hours: 1),
      clock: () => now,
    );
  });

  tearDown(() async {
    sdkReleaseLogSinkForTesting = null;
    await client.dispose();
  });

  MqttOperationalSosRequest sos() => MqttOperationalSosRequest(
    timestamp: now,
    triggerSource: 'ble_device_runtime_status',
    originatorNodeId: 7,
    cycleKey: 'sos:7:2',
  );

  test('MQTT down at SOS time: connects on demand and publishes', () async {
    expect(transports, isEmpty);

    await client.publishOperationalSos(sos());

    expect(transports, hasLength(1));
    expect(transports.single.published.single.topic, 'sos/alerts/$sdkUserId');
  });

  test('a link not proven alive recently is re-established before an SOS '
      'publish', () async {
    await client.publishOperationalSos(sos());
    now = now.add(const Duration(minutes: 5));

    await client.publishOperationalSos(sos());

    expect(transports, hasLength(2), reason: 'fresh connection for SOS');
    expect(transports.first.operations, contains('disconnect'));
    expect(transports.last.published, hasLength(1));
  });

  test('a fresh link is reused', () async {
    await client.publishOperationalSos(sos());
    now = now.add(const Duration(minutes: 1));

    await client.publishOperationalSos(sos());

    expect(transports, hasLength(1));
    expect(transports.single.published, hasLength(2));
  });

  test(
    'a publish without PUBACK is retried once on a fresh connection',
    () async {
      failNextPublishes = 1;

      await client.publishOperationalSos(sos());

      expect(transports, hasLength(2));
      expect(transports.last.published, hasLength(1));
    },
  );

  test(
    'two failed attempts surface an error (the outbox retries later)',
    () async {
      failNextPublishes = 2;

      await expectLater(
        client.publishOperationalSos(sos()),
        throwsA(isA<NetworkException>()),
      );
    },
  );

  test(
    'cancel is user-scoped `cancel: true` on the SOS alerts topic',
    () async {
      await client.publishOperationalSosCancel(timestamp: now);

      final message = transports.single.published.single;
      expect(message.topic, 'sos/alerts/$sdkUserId');
      final payload = jsonDecode(message.payload) as Map<String, dynamic>;
      expect(payload['cancel'], isTrue);
      expect(payload['timestamp'], now.toIso8601String());
      expect(payload.containsKey('deviceId'), isFalse);
      expect(payload.containsKey('hardwareId'), isFalse);
    },
  );
}

final class _Transport implements SdkMqttTransport {
  _Transport({required this.shouldFailPublish});

  final bool Function() shouldFailPublish;
  final List<String> operations = <String>[];
  final List<({String topic, String payload})> published =
      <({String topic, String payload})>[];
  final StreamController<SdkMqttIncomingMessage> _messages =
      StreamController<SdkMqttIncomingMessage>.broadcast();
  final StreamController<SdkMqttDisconnectEvent> _disconnects =
      StreamController<SdkMqttDisconnectEvent>.broadcast();

  @override
  Future<void> connect() async => operations.add('connect');

  @override
  Future<void> disconnect() async => operations.add('disconnect');

  @override
  Future<void> dispose() async {
    await _messages.close();
    await _disconnects.close();
  }

  @override
  Future<void> publish({
    required String topic,
    required String payload,
    SdkMqttQos qos = SdkMqttQos.atLeastOnce,
    bool retain = false,
  }) async {
    if (shouldFailPublish()) {
      throw TimeoutException('MQTT PUBACK not received');
    }
    published.add((topic: topic, payload: payload));
  }

  @override
  Future<void> subscribe(String topic) async {}

  @override
  Stream<SdkMqttDisconnectEvent> watchDisconnects() => _disconnects.stream;

  @override
  Stream<SdkMqttIncomingMessage> watchMessages() => _messages.stream;
}
