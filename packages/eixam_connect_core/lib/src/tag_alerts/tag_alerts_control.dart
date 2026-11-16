import 'tag_alert_permission_state.dart';
import 'tag_alert_settings.dart';

/// Optional TAG alerts capability. Detect with a type check; existing
/// `EixamConnectSdk` implementations need not implement it.
///
/// Alerts are local notifications generated on the phone. They are a
/// convenience and are not a guaranteed safety feature: the OS may delay or
/// drop them, and they never replace SOS flows.
abstract interface class TagAlertsControl {
  /// Settings for [deviceId] (see `tagAlertDeviceKey`). Returns defaults when
  /// nothing is stored or the stored data is unreadable; an unreadable store is
  /// reported as an error on [watchTagAlertSettings] instead of being thrown.
  Future<TagAlertSettings> getTagAlertSettings(String deviceId);

  /// Seeds the current settings, then emits every change. Persistence or
  /// restore failures arrive as stream errors; the stream stays usable.
  Stream<TagAlertSettings> watchTagAlertSettings(String deviceId);

  /// Persists [settings]. Throws `TagAlertsException` when persistence cannot
  /// be confirmed or the SDK has no session.
  Future<void> updateTagAlertSettings(TagAlertSettings settings);

  /// Never prompts.
  Future<TagAlertPermissionState> getTagAlertPermissionState();

  /// Prompts the user when the OS allows it. The SDK never calls this at
  /// bootstrap or by itself; hosts decide when to ask.
  Future<TagAlertPermissionState> requestTagAlertPermission();
}
