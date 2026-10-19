/// Recording lifecycle, independent of TAG input and history recovery.
enum ActivityRecordingPhase {
  /// Recording intent exists, including while no TAG is available.
  active,

  /// A fixed finish cutoff exists; bounded final recovery may still run.
  finalizing,

  /// The local result is fixed and cannot accept further route samples.
  finished,
}

/// Availability of the recording's TAG input path, not GPS-fix freshness.
enum ActivityRecordingInputState {
  /// No TAG identity has been bound to this recording.
  unbound,

  /// A TAG is bound but currently disconnected.
  disconnected,

  /// The matching TAG input path is attached; fresh samples are not implied.
  observing,

  /// A runtime restriction prevents establishing the input path.
  unavailable,
}

/// TAG history reconciliation, unrelated to backend or cloud synchronization.
enum ActivityRecordingRecoveryState {
  /// No recovery episode is running; route completeness is not implied.
  idle,

  /// A bounded TAG history reconciliation episode is running.
  recovering,

  /// Needed recovery cannot proceed or exhausted the current episode budget.
  deferred,
}

/// V1 never guarantees that every physical route sample was captured.
enum ActivityRecordingRouteQuality {
  /// No known interval lacks continuity, but completeness remains unproven.
  unknown,

  /// A known interval lacks defensible route continuity.
  partial,
}

/// Reconciliation of a declared interval of uncertain route continuity.
enum ActivityRecordingGapState {
  pending,
  recovering,
  unresolved,

  /// Retained TAG evidence reconciles this interval, not the entire route.
  reconciled,
}

/// Domain reasons for uncertain continuity, without transport-specific details.
enum ActivityRecordingGapReason {
  deviceUnavailable,
  runtimeUnavailable,
  rejectedSamples,
  ambiguousTimestamp,
  persistenceFailure,
}

/// Current degradations hosts may present; not a permanent error history.
///
/// Command failures use ActivityRecordingException separately. These facts also
/// describe asynchronous recording degradation without an outstanding command.
enum ActivityRecordingIssue {
  deviceIdentityUnavailable,
  commandOwnerUnavailable,
  recoveryFailed,
  recoveryTimedOut,
  persistenceFailed,
  invalidSamples,
  clockUncertain,
  storageLimit,
}
