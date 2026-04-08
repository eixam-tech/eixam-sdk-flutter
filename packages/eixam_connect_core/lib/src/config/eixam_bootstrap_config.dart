import 'eixam_custom_endpoints.dart';
import 'eixam_environment.dart';
import 'eixam_session.dart';

class EixamBootstrapConfig {
  const EixamBootstrapConfig({
    required this.appId,
    required this.environment,
    this.initialSession,
    this.customEndpoints,
    this.featureFlags = const <String, bool>{},
    this.enableLogging = false,
  });

  final String appId;
  final EixamEnvironment environment;
  final EixamSession? initialSession;
  final EixamCustomEndpoints? customEndpoints;
  final Map<String, bool> featureFlags;
  final bool enableLogging;
}
