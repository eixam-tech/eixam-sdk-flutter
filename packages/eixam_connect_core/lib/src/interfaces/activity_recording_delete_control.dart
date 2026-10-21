/// Optional, owner-scoped soft deletion of finished local recordings.
/// Discover with `sdk is ActivityRecordingDeleteControl`.
///
/// Deleted recordings disappear from normal public Recording and History reads.
/// Route payload may remain locally until normal account/local-user cleanup.
/// Deletion never contacts the backend or TAG and never changes Session, SOS,
/// DMP or device state. Hosts guard their own pending lifecycle orchestration
/// and refresh History/Detail presentation after success; no event is emitted.
abstract interface class ActivityRecordingDeleteControl {
  /// Marks a finished recording deleted within the current trusted owner.
  /// Repeating deletion succeeds. Absent/inaccessible IDs fail with
  /// E_RECORDING_NOT_FOUND; active/finalizing IDs fail with E_RECORDING_CONFLICT.
  /// Storage failures use the existing ActivityRecordingException conventions.
  Future<void> deleteFinishedActivityRecording({required String recordingId});
}
