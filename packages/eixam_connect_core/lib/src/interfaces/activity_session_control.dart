import '../entities/activity_session.dart';

/// Optional, identity-scoped logical sessions, independent of tracking and UI.
///
/// Discover through a typed capability check. EixamConnectSdk implementations
/// are not required to implement this interface.
abstract interface class ActivitySessionControl {
  Future<SdkActivitySession?> getActiveActivitySession();

  /// Seeds the current active session (or null), then emits committed changes.
  /// Restoration failures are stream errors, never a fabricated empty state.
  Stream<SdkActivitySession?> watchActiveActivitySession();

  /// Returns the existing session for the same active key; conflicts otherwise.
  /// Requires an authenticated SDK session. Does not request permissions.
  Future<SdkActivitySession> startActivitySession({
    required String activityKey,
  });

  /// Ends only the matching session. Repeating its end is a successful no-op.
  /// A different stored session ID conflicts; absent storage is a safe no-op.
  Future<void> endActivitySession({required String sessionId});
}
