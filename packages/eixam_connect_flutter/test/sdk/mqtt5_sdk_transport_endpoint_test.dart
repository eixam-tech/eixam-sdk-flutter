import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_bootstrap_resolver.dart';
import 'package:eixam_connect_flutter/src/sdk/mqtt5_sdk_transport.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_contract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('staging uses raw MQTT 5 over TLS on destination port 8883', () {
    final resolved = EixamBootstrapResolver.resolve(
      const EixamBootstrapConfig(
        appId: 'partner-app',
        environment: EixamEnvironment.staging,
        notificationTexts: _notificationTexts,
      ),
    );
    final request = SdkMqttContract.connectRequest(
      config: resolved.sdkConfig,
      session: const EixamSession.signed(
        appId: 'partner-app',
        externalUserId: 'partner-user',
        userHash: 'test-signature',
      ),
    );
    final endpoint = resolveMqtt5TransportEndpointSettings(request.brokerUri);

    expect(request.brokerUri.scheme, 'ssl');
    expect(request.brokerUri.host, 'mqtt.staging.eixam.io');
    expect(request.brokerUri.port, 8883);
    expect(endpoint.server, 'mqtt.staging.eixam.io');
    expect(endpoint.port, 8883);
    expect(endpoint.secure, isTrue);
    expect(endpoint.useWebSocket, isFalse);
  });
}

const _notificationTexts = EixamNotificationTexts(
  protectionActiveTitle: 'Protection active',
  protectionActiveBody: 'Protection is active.',
  protectionModeTitle: 'Protection mode',
  protectionModeBody: 'Protection mode is running.',
  protectionModeChannelName: 'Protection mode',
  protectionModeChannelDescription: 'Protection mode notifications.',
  protectionSosChannelName: 'SOS alerts',
  protectionSosChannelDescription: 'SOS lifecycle notifications.',
  protectionPreSosTitle: 'SOS countdown',
  protectionPreSosBody: 'SOS countdown is active.',
  protectionSosActiveTitle: 'SOS active',
  protectionSosActiveBody: 'SOS is active.',
  protectionSosResolvedTitle: 'SOS resolved',
  protectionSosResolvedBody: 'SOS is resolved.',
);
