import '../errors/activity_session_exception.dart';

/// A currently active logical activity. It does not imply live tracking.
final class SdkActivitySession {
  const SdkActivitySession({
    required this.sessionId,
    required this.activityKey,
    required this.startedAt,
  });

  final String sessionId;
  final String activityKey;

  /// SDK-produced values use UTC, sampled when the serialized start is accepted
  /// for persistence. Published only after commit verification, and unchanged
  /// by idempotent starts or restoration.
  final DateTime startedAt;

  /// Validates an extensible, stable identifier without normalizing it.
  static void validateActivityKey(String key) {
    if (key.isEmpty || key.length > 64 || !_activityKeyPattern.hasMatch(key)) {
      throw const ActivitySessionException(
        'E_ACTIVITY_INVALID_KEY',
        'Activity keys must contain 1–64 lowercase ASCII identifier characters.',
      );
    }
  }

  static final RegExp _activityKeyPattern = RegExp(
    r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$',
  );
}
