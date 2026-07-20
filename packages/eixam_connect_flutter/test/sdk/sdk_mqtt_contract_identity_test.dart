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
}
