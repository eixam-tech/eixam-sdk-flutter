import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_bootstrap_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EixamBootstrapResolver', () {
    test('resolves production endpoints internally', () {
      final resolved = EixamBootstrapResolver.resolve(
        const EixamBootstrapConfig(
          appId: 'partner-app',
          environment: EixamEnvironment.production,
        ),
      );

      expect(resolved.appId, 'partner-app');
      expect(
        resolved.sdkConfig.apiBaseUrl,
        EixamBootstrapResolver.productionApiBaseUrl,
      );
      expect(
        resolved.sdkConfig.websocketUrl,
        EixamBootstrapResolver.productionWebsocketUrl,
      );
    });

    test('resolves staging endpoints internally with TLS MQTT transport', () {
      final resolved = EixamBootstrapResolver.resolve(
        const EixamBootstrapConfig(
          appId: 'partner-app',
          environment: EixamEnvironment.staging,
        ),
      );

      expect(resolved.appId, 'partner-app');
      expect(
        resolved.sdkConfig.apiBaseUrl,
        EixamBootstrapResolver.stagingApiBaseUrl,
      );
      expect(
        resolved.sdkConfig.websocketUrl,
        EixamBootstrapResolver.stagingWebsocketUrl,
      );
      expect(
        resolved.sdkConfig.websocketUrl,
        'ssl://mqtt.staging.eixam.io:8883',
      );
    });

    test('uses custom endpoints when custom environment is selected', () {
      final resolved = EixamBootstrapResolver.resolve(
        const EixamBootstrapConfig(
          appId: 'partner-app',
          environment: EixamEnvironment.custom,
          customEndpoints: EixamCustomEndpoints(
            apiBaseUrl: 'https://custom.example',
            websocketUrl: 'wss://custom.example/ws',
          ),
        ),
      );

      expect(resolved.sdkConfig.apiBaseUrl, 'https://custom.example');
      expect(resolved.sdkConfig.websocketUrl, 'wss://custom.example/ws');
    });

    test('allows mqttUrl as the custom realtime endpoint fallback', () {
      final resolved = EixamBootstrapResolver.resolve(
        const EixamBootstrapConfig(
          appId: 'partner-app',
          environment: EixamEnvironment.custom,
          customEndpoints: EixamCustomEndpoints(
            apiBaseUrl: 'https://custom.example',
            mqttUrl: 'wss://custom.example/mqtt',
          ),
        ),
      );

      expect(resolved.sdkConfig.websocketUrl, 'wss://custom.example/mqtt');
    });

    test('rejects missing custom endpoints', () {
      expect(
        () => EixamBootstrapResolver.resolve(
          const EixamBootstrapConfig(
            appId: 'partner-app',
            environment: EixamEnvironment.custom,
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects custom endpoints for non-custom environments', () {
      expect(
        () => EixamBootstrapResolver.resolve(
          const EixamBootstrapConfig(
            appId: 'partner-app',
            environment: EixamEnvironment.sandbox,
            customEndpoints: EixamCustomEndpoints(
              apiBaseUrl: 'https://custom.example',
              websocketUrl: 'wss://custom.example/ws',
            ),
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects initial session when app ids do not match', () {
      expect(
        () => EixamBootstrapResolver.resolve(
          const EixamBootstrapConfig(
            appId: 'partner-app',
            environment: EixamEnvironment.production,
            initialSession: EixamSession.signed(
              appId: 'different-app',
              externalUserId: 'user-1',
              userHash: 'signed-value',
            ),
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('flags restored sessions that belong to a different app id', () {
      expect(
        EixamBootstrapResolver.restoredSessionMatchesApp(
          const EixamSession.signed(
            appId: 'partner-app',
            externalUserId: 'user-1',
            userHash: 'signed-value',
          ),
          'partner-app',
        ),
        isTrue,
      );
      expect(
        EixamBootstrapResolver.restoredSessionMatchesApp(
          const EixamSession.signed(
            appId: 'legacy-app',
            externalUserId: 'user-1',
            userHash: 'signed-value',
          ),
          'partner-app',
        ),
        isFalse,
      );
    });
  });
}
