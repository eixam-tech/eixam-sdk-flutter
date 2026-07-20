import 'dart:async';
import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/sdk/mqtt_realtime_client.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_contract.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const internalUserId = '1641f888-49aa-458f-9a32-ecbac516f44e';
  const externalUserId = 'a475f91b-02e7-4092-b13a-d8e882ed9b50';
  const session = EixamSession(
    appId: 'commercial-app',
    externalUserId: externalUserId,
    canonicalExternalUserId: externalUserId,
    sdkUserId: internalUserId,
    userHash: 'not-a-real-secret',
  );

  late SdkSessionContext sessionContext;
  late List<_FakeMqttTransport> transports;
  late MqttRealtimeClient client;

  setUp(() async {
    await BleDebugRegistry.instance.resetForLifecycle();
    sessionContext = SdkSessionContext()..currentSession = session;
    transports = <_FakeMqttTransport>[];
    client = MqttRealtimeClient(
      config: const EixamSdkConfig(
        apiBaseUrl: 'https://api.example.test',
        websocketUrl: 'wss://mqtt.example.test/mqtt',
        enableLogging: true,
      ),
      sessionContext: sessionContext,
      transportFactory: (_) {
        final transport = _FakeMqttTransport();
        transports.add(transport);
        return transport;
      },
      reconnectDelay: Duration.zero,
    );
  });

  tearDown(() async {
    await client.dispose();
  });

  test('subscriptions are active before operational SOS publication', () async {
    await client.publishOperationalSos(MqttOperationalSosRequest(
      timestamp: DateTime.now().toUtc(),
      triggerSource: 'button_ui',
    ));

    final transport = transports.single;
    expect(
      transport.operations,
      <String>[
        'connect',
        'subscribe:sos/events/$internalUserId',
        'subscribe:sos/events/$externalUserId',
        'publish:sos/alerts/$internalUserId',
      ],
    );
    expect(_hasDiagnostic('SOS_MQTT_EVENT_SUBSCRIPTION_REQUESTED'), isTrue);
    expect(_hasDiagnostic('SOS_MQTT_EVENT_SUBSCRIPTION_ACTIVE'), isTrue);
    expect(_hasDiagnostic('SOS_MQTT_SOS_READY'), isTrue);
  });

  test('transport adds trusted topic metadata before repository delivery',
      () async {
    await client.connect();
    final eventFuture = client.watchEvents().first;
    final now = DateTime.now().toUtc();
    transports.single.emitMessage(
      topic: 'sos/events/$internalUserId',
      payload: jsonEncode(<String, dynamic>{
        'type': 'processed',
        'userId': internalUserId,
        'incidentId': '7c9e6679-7425-40de-944b-e07fc1f90ae7',
        'status': 'active',
        'occurredAt': now.toIso8601String(),
        'openedAt': now.toIso8601String(),
        'updatedAt': now.toIso8601String(),
        'snapshotVersion': 1,
      }),
    );

    final event = await eventFuture;
    expect(event.type, 'processed');
    expect(event.payload!['_mqttAuthenticatedUserScoped'], isTrue);
    expect(event.payload!['_mqttTopicCategory'], 'internal');
    expect(_hasDiagnostic('SOS_MQTT_EVENT_RECEIVED'), isTrue);
    expect(_hasDiagnostic('SOS_MQTT_EVENT_PARSED'), isTrue);
  });

  test('malformed payload is rejected without reaching lifecycle listeners',
      () async {
    await client.connect();
    var delivered = false;
    final subscription = client.watchEvents().listen((_) => delivered = true);
    transports.single.emitMessage(
      topic: 'sos/events/$internalUserId',
      payload: '{invalid',
    );
    await Future<void>.delayed(Duration.zero);

    expect(delivered, isFalse);
    expect(_hasDiagnostic('SOS_MQTT_EVENT_PARSE_REJECTED'), isTrue);
    await subscription.cancel();
  });

  test('a new connection resubscribes before SOS can publish again', () async {
    await client.connect();
    await client.disconnect();
    await client.publishOperationalSos(MqttOperationalSosRequest(
      timestamp: DateTime.now().toUtc(),
      triggerSource: 'button_ui',
    ));

    expect(transports, hasLength(2));
    final second = transports.last.operations;
    expect(second.first, 'connect');
    expect(second[1], 'subscribe:sos/events/$internalUserId');
    expect(second[2], 'subscribe:sos/events/$externalUserId');
    expect(second.last, 'publish:sos/alerts/$internalUserId');
  });
}

bool _hasDiagnostic(String token) {
  return BleDebugRegistry.instance.currentState.events.any(
    (event) => event.message.contains(token),
  );
}

final class _FakeMqttTransport implements SdkMqttTransport {
  final StreamController<SdkMqttIncomingMessage> _messages =
      StreamController<SdkMqttIncomingMessage>.broadcast();
  final StreamController<SdkMqttDisconnectEvent> _disconnects =
      StreamController<SdkMqttDisconnectEvent>.broadcast();
  final List<String> operations = <String>[];

  @override
  Future<void> connect() async {
    operations.add('connect');
  }

  @override
  Future<void> disconnect() async {
    operations.add('disconnect');
  }

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
    operations.add('publish:$topic');
  }

  @override
  Future<void> subscribe(String topic) async {
    operations.add('subscribe:$topic');
  }

  @override
  Stream<SdkMqttDisconnectEvent> watchDisconnects() => _disconnects.stream;

  @override
  Stream<SdkMqttIncomingMessage> watchMessages() => _messages.stream;

  void emitMessage({required String topic, required String payload}) {
    _messages.add(SdkMqttIncomingMessage(topic: topic, payload: payload));
  }
}
