import 'eixam_custom_endpoints.dart';
import 'eixam_environment.dart';
import 'eixam_session.dart';

enum EixamNotificationPolicy {
  sdkManaged,
  hostAppManaged,
}

class EixamBootstrapConfig {
  const EixamBootstrapConfig({
    required this.appId,
    required this.environment,
    this.initialSession,
    this.customEndpoints,
    this.notificationPolicy = EixamNotificationPolicy.sdkManaged,
    this.featureFlags = const <String, bool>{},
    this.enableLogging = false,
  });

  final String appId;
  final EixamEnvironment environment;
  final EixamSession? initialSession;
  final EixamCustomEndpoints? customEndpoints;
  final EixamNotificationPolicy notificationPolicy;
  final Map<String, bool> featureFlags;
  final bool enableLogging;
}
