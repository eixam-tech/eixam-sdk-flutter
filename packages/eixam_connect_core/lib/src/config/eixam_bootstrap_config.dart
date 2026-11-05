import 'eixam_custom_endpoints.dart';
import 'eixam_environment.dart';
import 'eixam_session.dart';
import '../entities/permission_disclosure.dart';
import '../tag_alerts/tag_alert_notifier.dart';
import '../tag_alerts/tag_alert_text.dart';

enum EixamNotificationPolicy { sdkManaged, hostAppManaged }

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
    this.tagAlertNotifier,
    this.tagAlertTextResolver,
    this.dfuRecovery = const EixamDfuRecoveryConfig(),
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

  /// Optional host delivery for TAG alerts. Null uses the SDK's default local
  /// notification adapter.
  final TagAlertNotifier? tagAlertNotifier;

  /// Optional localized wording for the default TAG alert adapter. Null uses
  /// neutral English text. Ignored when [tagAlertNotifier] is supplied.
  final TagAlertTextResolver? tagAlertTextResolver;

  /// Interrupted-DFU recovery behaviour (see `DfuRecoveryControl`).
  final EixamDfuRecoveryConfig dfuRecovery;
}

/// Options of the interrupted-DFU recovery capability.
class EixamDfuRecoveryConfig {
  const EixamDfuRecoveryConfig({
    this.silenceWindow = const Duration(minutes: 2),
    this.observeInterval = const Duration(seconds: 30),
  });

  /// How long an interrupted TAG must stay unseen before it is reported as
  /// `silentNeedsCable`.
  final Duration silenceWindow;

  /// Minimum spacing between BLE scans made on behalf of `watchDfuRecovery()`
  /// (Android throttles scan starts).
  final Duration observeInterval;
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
    this.nearbyMessageChannelName = 'Nearby',
    this.nearbyMessageChannelDescription = 'Incoming nearby messages',
    this.nearbyMessageFallbackTitle = 'Nearby',
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
  final String nearbyMessageChannelName;
  final String nearbyMessageChannelDescription;
  final String nearbyMessageFallbackTitle;
}
