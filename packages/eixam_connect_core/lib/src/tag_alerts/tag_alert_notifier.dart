import 'tag_alert.dart';

/// Port that delivers TAG alerts to the user. The SDK ships a default adapter
/// over local notifications; hosts may plug in their own.
///
/// (deviceId, kind) identifies one slot. Implementations must keep at most one
/// shown-or-scheduled alert per slot: [show] and [schedule] replace it.
abstract interface class TagAlertNotifier {
  /// Shows [alert] now, replacing the slot's previous alert.
  Future<void> show(TagAlert alert);

  /// Schedules [alert] for [at] (absolute instant), replacing whatever the
  /// slot had. Idempotent, and cheap enough to be called repeatedly to push
  /// the same alert forward.
  Future<void> schedule(TagAlert alert, DateTime at);

  /// Removes the slot's scheduled and already-delivered alert.
  Future<void> cancel(String deviceId, TagAlertKind kind);

  /// Removes every scheduled and delivered alert of [deviceId].
  Future<void> cancelAllForDevice(String deviceId);

  /// Removes every scheduled and delivered TAG alert.
  Future<void> cancelAll();
}
