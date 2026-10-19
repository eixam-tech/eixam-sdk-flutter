import 'activity_recording_record.dart';

/// Private transactional boundary. Implementations must roll back callback
/// errors and resolve uncertain acknowledgements before reporting success.
abstract interface class ActivityRecordingStore {
  Object get writerNamespace;
  Future<T> transaction<T>(
    Future<T> Function(ActivityRecordingTransaction tx) action,
  );
  Future<void> clear();
  Future<void> dispose();
}

abstract interface class ActivityRecordingTransaction {
  /// Adopts only this principal, purging other ownership atomically. Returns
  /// true after purging a confirmed canonical conflict so callers can quarantine.
  Future<bool> reconcileOwner(ActivityRecordingOwner owner);
  Future<ActivityRecordingRecord?> active(String scope);
  Future<ActivityRecordingRecord?> byId(String scope, String recordingId);
  Future<ActivityRecordingRecord?> forSession(String scope, String sessionId);
  Future<void> insert(ActivityRecordingRecord record);
  Future<void> update(ActivityRecordingRecord record);
  Future<void> verifyEmptyRoute(String recordingId);
}
