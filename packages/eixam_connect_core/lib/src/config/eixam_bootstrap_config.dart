import 'eixam_custom_endpoints.dart';
import 'eixam_environment.dart';
import 'eixam_session.dart';
import '../entities/permission_disclosure.dart';

enum EixamNotificationPolicy {
  sdkManaged,
  hostAppManaged,
}

class EixamBootstrapConfig {
  const EixamBootstrapConfig({
    required this.appId,
    required this.environment,
    required this.notificationTexts,
    this.initialSession,
    this.customEndpoints,
    this.notificationPolicy = EixamNotificationPolicy.sdkManaged,
    this.permissionDisclosureConfig = const EixamPermissionDisclosureConfig(),
    this.featureFlags = const <String, bool>{},
    this.enableLogging = false,
    this.allowInsecureLocalEndpoints = false,
  });

  final String appId;
  final EixamEnvironment environment;
  final EixamNotificationTexts notificationTexts;
  final EixamSession? initialSession;
  final EixamCustomEndpoints? customEndpoints;
  final EixamNotificationPolicy notificationPolicy;
  final EixamPermissionDisclosureConfig permissionDisclosureConfig;
  final Map<String, bool> featureFlags;
  final bool enableLogging;
  final bool allowInsecureLocalEndpoints;
}

class EixamNotificationTexts {
  const EixamNotificationTexts({
    required this.protectionActiveTitle,
    required this.protectionActiveBody,
    required this.protectionModeTitle,
    required this.protectionModeBody,
    required this.protectionModeChannelName,
    required this.protectionModeChannelDescription,
    required this.protectionSosChannelName,
    required this.protectionSosChannelDescription,
    required this.protectionPreSosTitle,
    required this.protectionPreSosBody,
    required this.protectionSosActiveTitle,
    required this.protectionSosActiveBody,
    required this.protectionSosResolvedTitle,
    required this.protectionSosResolvedBody,
  });

  final String protectionActiveTitle;
  final String protectionActiveBody;
  final String protectionModeTitle;
  final String protectionModeBody;
  final String protectionModeChannelName;
  final String protectionModeChannelDescription;
  final String protectionSosChannelName;
  final String protectionSosChannelDescription;
  final String protectionPreSosTitle;
  final String protectionPreSosBody;
  final String protectionSosActiveTitle;
  final String protectionSosActiveBody;
  final String protectionSosResolvedTitle;
  final String protectionSosResolvedBody;
}
