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
          notificationTexts: _notificationTexts,
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
          notificationTexts: _notificationTexts,
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
          notificationTexts: _notificationTexts,
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
          notificationTexts: _notificationTexts,
          customEndpoints: EixamCustomEndpoints(
            apiBaseUrl: 'https://custom.example',
            mqttUrl: 'wss://custom.example/mqtt',
          ),
        ),
      );

      expect(resolved.sdkConfig.websocketUrl, 'wss://custom.example/mqtt');
    });

    test('rejects insecure custom endpoints by default', () {
      expect(
        () => EixamBootstrapResolver.resolve(
          const EixamBootstrapConfig(
            appId: 'partner-app',
            environment: EixamEnvironment.custom,
            notificationTexts: _notificationTexts,
            customEndpoints: EixamCustomEndpoints(
              apiBaseUrl: 'http://api.example.test',
              websocketUrl: 'ws://mqtt.example.test/ws',
            ),
          ),
        ),
        throwsA(isA<TransportSecurityException>()),
      );
    });

    test('allows insecure localhost custom endpoints with explicit debug flag',
        () {
      final resolved = EixamBootstrapResolver.resolve(
        const EixamBootstrapConfig(
          appId: 'partner-app',
          environment: EixamEnvironment.custom,
          notificationTexts: _notificationTexts,
          allowInsecureLocalEndpoints: true,
          customEndpoints: EixamCustomEndpoints(
            apiBaseUrl: 'http://localhost:8080',
            websocketUrl: 'ws://localhost:9001/mqtt',
          ),
        ),
      );

      expect(resolved.sdkConfig.apiBaseUrl, 'http://localhost:8080');
      expect(resolved.sdkConfig.websocketUrl, 'ws://localhost:9001/mqtt');
      expect(resolved.sdkConfig.allowInsecureLocalEndpoints, isTrue);
    });

    test('rejects missing custom endpoints', () {
      expect(
        () => EixamBootstrapResolver.resolve(
          const EixamBootstrapConfig(
            appId: 'partner-app',
            environment: EixamEnvironment.custom,
            notificationTexts: _notificationTexts,
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
            notificationTexts: _notificationTexts,
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
            notificationTexts: _notificationTexts,
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

    test('rejects empty notification text values', () {
      expect(
        () => EixamBootstrapResolver.resolve(
          const EixamBootstrapConfig(
            appId: 'partner-app',
            environment: EixamEnvironment.production,
            notificationTexts: EixamNotificationTexts(
              protectionActiveTitle: '',
              protectionActiveBody: 'Sharing safety status.',
              protectionModeTitle: 'Protection mode',
              protectionModeBody: 'Keeping the device connected.',
              protectionModeChannelName: 'Protection mode',
              protectionModeChannelDescription: 'Protection status.',
              protectionSosChannelName: 'Protection SOS',
              protectionSosChannelDescription: 'Protection SOS alerts.',
              protectionPreSosTitle: 'SOS pre-alert',
              protectionPreSosBody: 'Possible SOS.',
              protectionSosActiveTitle: 'SOS active',
              protectionSosActiveBody: 'SOS activated.',
              protectionSosResolvedTitle: 'SOS resolved',
              protectionSosResolvedBody: 'SOS ended.',
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

const _notificationTexts = EixamNotificationTexts(
  protectionActiveTitle: 'Protection active',
  protectionActiveBody: 'Sharing safety status.',
  protectionModeTitle: 'Protection mode',
  protectionModeBody: 'Keeping the device connected.',
  protectionModeChannelName: 'Protection mode',
  protectionModeChannelDescription: 'Protection status.',
  protectionSosChannelName: 'Protection SOS',
  protectionSosChannelDescription: 'Protection SOS alerts.',
  protectionPreSosTitle: 'SOS pre-alert',
  protectionPreSosBody: 'Possible SOS.',
  protectionSosActiveTitle: 'SOS active',
  protectionSosActiveBody: 'SOS activated.',
  protectionSosResolvedTitle: 'SOS resolved',
  protectionSosResolvedBody: 'SOS ended.',
);
