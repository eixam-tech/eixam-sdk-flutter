import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_contract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses backend SDK user id for publish and subscribes to both identities',
      () {
    const backendUserId = '1641f888-49aa-458f-9a32-ecbac516f44e';
    const authenticationUserId = 'a475f91b-02e7-4092-b13a-d8e882ed9b50';
    const session = EixamSession(
      appId: 'commercial-app',
      externalUserId: authenticationUserId,
      canonicalExternalUserId: authenticationUserId,
      sdkUserId: backendUserId,
      userHash: 'not-a-real-secret',
    );

    final envelope = SdkMqttContract.buildOperationalSosEnvelope(
      sdkUserId: backendUserId,
      request: MqttOperationalSosRequest(
        timestamp: DateTime.utc(2026, 7, 20),
        triggerSource: 'button_ui',
      ),
    );
    final payload = jsonDecode(envelope.payload) as Map<String, dynamic>;

    expect(envelope.topic, 'sos/alerts/$backendUserId');
    expect(payload.containsKey('userId'), isFalse);
    expect(
      SdkMqttTopics.eventTopicsFor(session),
      <String>{
        'sos/events/$backendUserId',
        'sos/events/$authenticationUserId',
      },
    );
  });

  // The backend binds the origin tag's cycle to the incident. Only a cycle-bound
  // relay receipt knows it; local keys name no firmware cycle.
  group('operational SOS names the origin cycle', () {
    Map<String, dynamic> payloadFor(String? cycleKey) {
      final envelope = SdkMqttContract.buildOperationalSosEnvelope(
        sdkUserId: '1641f888-49aa-458f-9a32-ecbac516f44e',
        request: MqttOperationalSosRequest(
          timestamp: DateTime.utc(2026, 7, 20),
          deviceId: '1670275441',
          originatorNodeId: 1670275441,
          relayNodeId: 99,
          relaySource: 'remote_lora_relay',
          cycleKey: cycleKey,
        ),
      );
      return jsonDecode(envelope.payload) as Map<String, dynamic>;
    }

    test('cycle-bound relay receipt', () {
      final payload = payloadFor('lora:1670275441:4080427857');
      expect(payload['mesh'], <String, dynamic>{'cycle': 4080427857});
      expect(payload['deviceId'], '1670275441');
      expect(payload.containsKey('cycleKey'), isFalse);
    });

    test('local and unbound keys', () {
      for (final key in <String?>[
        null,
        '',
        'sos-1721433600000000',
        '1670275441:7',
        'sos:1670275441:7',
        'lora:1670275441:0',
        'lora:1670275441:4294967296',
        'lora:1670275441:abc',
      ]) {
        expect(payloadFor(key).containsKey('mesh'), isFalse, reason: '$key');
      }
    });
  });
}
