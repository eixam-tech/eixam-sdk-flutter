import '../entities/activity_availability.dart';

/// Optional, endpoint-backed app assignment capability. Detect with a type check;
/// existing EixamConnectSdk implementations need not implement this interface.
/// No session, tracking, SOS, DMP, partner, or UI lifecycle is implied.
abstract interface class ActivityAvailabilityControl {
  /// No network. Null means no usable snapshot, unlike a confirmed empty list.
  /// Unreadable/corrupt storage raises ActivityAvailabilityException.
  Future<SdkActivityAvailability?> getCachedActivityAvailability();

  /// Explicit authoritative refresh. Temporary failure retains last-known-good
  /// data; authentication rejection invalidates it. Concurrent requests coalesce.
  Future<SdkActivityAvailability> refreshActivityAvailability();

  /// Seeds cached/current state, then replacements/invalidation, without fetching.
  /// Identity changes discard buffered previous-identity values and errors.
  Stream<SdkActivityAvailability?> watchActivityAvailability();
}
