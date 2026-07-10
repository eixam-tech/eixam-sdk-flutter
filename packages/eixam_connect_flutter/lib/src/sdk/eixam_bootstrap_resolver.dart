import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'transport_security_validator.dart';

class ResolvedEixamBootstrapConfig {
  const ResolvedEixamBootstrapConfig({
    required this.appId,
    required this.sdkConfig,
    this.initialSession,
  });

  final String appId;
  final EixamSdkConfig sdkConfig;
  final EixamSession? initialSession;
}

class EixamBootstrapResolver {
  static const String productionApiBaseUrl = 'https://api.eixam.io';
  static const String productionWebsocketUrl = 'wss://api.eixam.io/ws';
  static const String sandboxApiBaseUrl = 'https://api.sandbox.eixam.io';
  static const String sandboxWebsocketUrl = 'wss://api.sandbox.eixam.io/ws';
  static const String stagingApiBaseUrl = 'https://api.staging.eixam.io/';
  static const String stagingWebsocketUrl = 'ssl://mqtt.staging.eixam.io:8883';

  static ResolvedEixamBootstrapConfig resolve(EixamBootstrapConfig config) {
    final appId = config.appId.trim();
    if (appId.isEmpty) {
      throw ArgumentError.value(
        config.appId,
        'appId',
        'EixamBootstrapConfig.appId must not be empty.',
      );
    }
    _validateNotificationTexts(config.notificationTexts);

    if (config.environment == EixamEnvironment.custom) {
      final endpoints = config.customEndpoints;
      if (endpoints == null) {
        throw ArgumentError(
          'EixamBootstrapConfig.customEndpoints is required when '
          'environment is EixamEnvironment.custom.',
        );
      }

      final apiBaseUrl = endpoints.apiBaseUrl.trim();
      if (apiBaseUrl.isEmpty) {
        throw ArgumentError.value(
          endpoints.apiBaseUrl,
          'customEndpoints.apiBaseUrl',
          'customEndpoints.apiBaseUrl must not be empty.',
        );
      }

      final websocketUrl =
          (endpoints.websocketUrl ?? endpoints.mqttUrl ?? '').trim();
      if (websocketUrl.isEmpty) {
        throw ArgumentError(
          'A custom bootstrap configuration must include either '
          'customEndpoints.websocketUrl or customEndpoints.mqttUrl.',
        );
      }

      final initialSession = _validateInitialSession(
        expectedAppId: appId,
        initialSession: config.initialSession,
      );

      return ResolvedEixamBootstrapConfig(
        appId: appId,
        sdkConfig: EixamSdkConfig(
          apiBaseUrl: apiBaseUrl,
          websocketUrl: websocketUrl,
          enableLogging: config.enableLogging,
          allowInsecureLocalEndpoints: config.allowInsecureLocalEndpoints,
        ),
        initialSession: initialSession,
      )..validateTransportSecurity();
    }

    if (config.customEndpoints != null) {
      throw ArgumentError(
        'customEndpoints can be used only when environment is '
        'EixamEnvironment.custom.',
      );
    }

    final resolvedEndpoints = switch (config.environment) {
      EixamEnvironment.production => (
          productionApiBaseUrl,
          productionWebsocketUrl,
        ),
      EixamEnvironment.sandbox => (
          sandboxApiBaseUrl,
          sandboxWebsocketUrl,
        ),
      EixamEnvironment.staging => (
          stagingApiBaseUrl,
          stagingWebsocketUrl,
        ),
      EixamEnvironment.custom => throw StateError(
          'Custom environment should be handled before fixed resolution.',
        ),
    };

    final initialSession = _validateInitialSession(
      expectedAppId: appId,
      initialSession: config.initialSession,
    );

    return ResolvedEixamBootstrapConfig(
      appId: appId,
      sdkConfig: EixamSdkConfig(
        apiBaseUrl: resolvedEndpoints.$1,
        websocketUrl: resolvedEndpoints.$2,
        enableLogging: config.enableLogging,
        allowInsecureLocalEndpoints: config.allowInsecureLocalEndpoints,
      ),
      initialSession: initialSession,
    )..validateTransportSecurity();
  }

  static bool restoredSessionMatchesApp(
    EixamSession? restoredSession,
    String appId,
  ) {
    if (restoredSession == null) {
      return true;
    }
    return restoredSession.appId.trim() == appId.trim();
  }

  static EixamSession? _validateInitialSession({
    required String expectedAppId,
    required EixamSession? initialSession,
  }) {
    if (initialSession == null) {
      return null;
    }

    if (initialSession.appId.trim() != expectedAppId) {
      throw ArgumentError(
        'EixamBootstrapConfig.initialSession.appId must match '
        'EixamBootstrapConfig.appId.',
      );
    }

    return initialSession;
  }

  static void _validateNotificationTexts(EixamNotificationTexts texts) {
    final values = <String, String>{
      'notificationTexts.protectionActiveTitle': texts.protectionActiveTitle,
      'notificationTexts.protectionActiveBody': texts.protectionActiveBody,
      'notificationTexts.protectionModeTitle': texts.protectionModeTitle,
      'notificationTexts.protectionModeBody': texts.protectionModeBody,
      'notificationTexts.protectionModeChannelName':
          texts.protectionModeChannelName,
      'notificationTexts.protectionModeChannelDescription':
          texts.protectionModeChannelDescription,
      'notificationTexts.protectionSosChannelName':
          texts.protectionSosChannelName,
      'notificationTexts.protectionSosChannelDescription':
          texts.protectionSosChannelDescription,
      'notificationTexts.protectionPreSosTitle': texts.protectionPreSosTitle,
      'notificationTexts.protectionPreSosBody': texts.protectionPreSosBody,
      'notificationTexts.protectionSosActiveTitle':
          texts.protectionSosActiveTitle,
      'notificationTexts.protectionSosActiveBody':
          texts.protectionSosActiveBody,
      'notificationTexts.protectionSosResolvedTitle':
          texts.protectionSosResolvedTitle,
      'notificationTexts.protectionSosResolvedBody':
          texts.protectionSosResolvedBody,
    };
    for (final entry in values.entries) {
      if (entry.value.trim().isEmpty) {
        throw ArgumentError.value(
          entry.value,
          entry.key,
          'EixamBootstrapConfig.notificationTexts values must not be empty.',
        );
      }
    }
  }
}

extension on ResolvedEixamBootstrapConfig {
  void validateTransportSecurity() {
    SdkTransportSecurityValidator.validateConfig(sdkConfig);
  }
}
