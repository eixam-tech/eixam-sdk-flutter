import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:eixam_connect_flutter/src/sdk/mqtt5_sdk_transport.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_contract.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

void main() {
  group('SDK transport security validation', () {
    test('accepts HTTPS API endpoints', () {
      expect(
        () => SdkHttpTransport(
          client: MockClient((_) async => throw UnimplementedError()),
          config: const EixamSdkConfig(
            apiBaseUrl: 'https://api.example.test',
          ),
          sessionContext: SdkSessionContext(),
        ),
        returnsNormally,
      );
    });

    test('rejects HTTP API endpoints by default', () {
      expect(
        () => SdkHttpTransport(
          client: MockClient((_) async => throw UnimplementedError()),
          config: const EixamSdkConfig(
            apiBaseUrl: 'http://api.example.test',
          ),
          sessionContext: SdkSessionContext(),
        ),
        throwsA(
          isA<TransportSecurityException>().having(
            (error) => error.code,
            'code',
            'E_SDK_INSECURE_API_ENDPOINT',
          ),
        ),
      );
    });

    test('accepts WSS MQTT endpoints', () {
      final request = SdkMqttContract.connectRequest(
        config: const EixamSdkConfig(
          apiBaseUrl: 'https://api.example.test',
          websocketUrl: 'wss://mqtt.example.test/ws',
        ),
        session: _session,
      );

      expect(request.brokerUri.scheme, 'wss');
    });

    test('rejects WS and plain MQTT endpoints by default', () {
      expect(
        () => SdkMqttContract.connectRequest(
          config: const EixamSdkConfig(
            apiBaseUrl: 'https://api.example.test',
            websocketUrl: 'ws://mqtt.example.test/ws',
          ),
          session: _session,
        ),
        throwsA(isA<TransportSecurityException>()),
      );
      expect(
        () => SdkMqttContract.connectRequest(
          config: const EixamSdkConfig(
            apiBaseUrl: 'https://api.example.test',
            websocketUrl: 'mqtt://mqtt.example.test:1883',
          ),
          session: _session,
        ),
        throwsA(isA<TransportSecurityException>()),
      );
    });

    test('accepts localhost insecure endpoints only with debug override', () {
      expect(
        () => SdkHttpTransport(
          client: MockClient((_) async => throw UnimplementedError()),
          config: const EixamSdkConfig(
            apiBaseUrl: 'http://localhost:8080',
          ),
          sessionContext: SdkSessionContext(),
        ),
        throwsA(isA<TransportSecurityException>()),
      );

      expect(
        () => SdkHttpTransport(
          client: MockClient((_) async => throw UnimplementedError()),
          config: const EixamSdkConfig(
            apiBaseUrl: 'http://localhost:8080',
            allowInsecureLocalEndpoints: true,
          ),
          sessionContext: SdkSessionContext(),
        ),
        returnsNormally,
      );

      final localRequest = SdkMqttContract.connectRequest(
        config: const EixamSdkConfig(
          apiBaseUrl: 'https://api.example.test',
          websocketUrl: 'ws://localhost:9001/mqtt',
          allowInsecureLocalEndpoints: true,
        ),
        session: _session,
      );

      expect(
        () => Mqtt5SdkTransport(
          request: localRequest,
          enableLogging: false,
        ),
        returnsNormally,
      );
      expect(
        () => SdkMqttContract.connectRequest(
          config: const EixamSdkConfig(
            apiBaseUrl: 'https://api.example.test',
            websocketUrl: 'ws://localhost:9001/mqtt',
          ),
          session: _session,
        ),
        throwsA(isA<TransportSecurityException>()),
      );
    });
  });
}

const _session = EixamSession.signed(
  appId: 'partner-app',
  externalUserId: 'user-1',
  userHash: 'signed-hash',
);
