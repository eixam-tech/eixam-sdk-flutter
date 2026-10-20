import '../entities/activity_recording.dart';
import '../entities/activity_recording_route.dart';
import '../entities/activity_session.dart';

/// Optional, local-only, identity-scoped TAG route recording.
///
/// Discover with `sdk is ActivityRecordingControl`; existing EixamConnectSdk
/// implementations need not implement this interface. AR1 supplies the contract
/// only. Production runtime implementation is a separate delivery stage.
///
/// Recording never starts/ends ActivitySession, phone tracking, SOS, DMP or
/// Protection Mode, and never acquires OTA/provisioning ownership. Phone GPS and
/// backend reconstruction never fill TAG-route gaps. Remote activity availability
/// does not own or gate local recording persistence/restoration.
///
/// One active/finalizing recording is allowed per logical identity. Multiple
/// finished recordings remain local; finishing another never replaces them.
/// Account/backend/app replacement cannot migrate recording data. Logout/account
/// cleanup follows identity privacy rules; no automatic age retention is implied.
abstract interface class ActivityRecordingControl {
  /// Returns the active or finalizing recording, or confirmed absence.
  /// Unreadable storage must report an error, never fabricated absence.
  Future<SdkActivityRecording?> getActiveActivityRecording();

  /// Seeds current active/finalizing state (or null), then committed changes.
  /// No route arrays are emitted. Identity changes fence buffered values/errors.
  /// Restore failures are stream errors; finished records use known-ID lookup.
  Stream<SdkActivityRecording?> watchActiveActivityRecording();

  /// Creates a recording explicitly associated with the same-identity active
  /// session. The session tuple must match; its key follows the existing
  /// SdkActivitySession grammar without normalization or catalog restrictions.
  ///
  /// The same association returns the existing active recording unchanged;
  /// another association or conflicting supplied TAG conflicts. Reusing a
  /// retained finished association fails with E_RECORDING_ALREADY_FINISHED.
  /// A missing TAG permits active/unbound or active/disconnected intent.
  /// A supplied TAG must be verifiable, but need not currently be connected.
  /// Supported source identities are legacy canonical MACs and registered nodes
  /// encoded exactly as `node:<decimal>` (1..4294967294, no leading zeroes).
  /// Node binding verifies the current paired, provisioned device's node and
  /// authenticated assignment without creating an assignment. Hosts own fresh
  /// connected-device preflight when their product requires it at Session Start.
  /// No phone fallback, permissions request or implicit device selection occurs.
  Future<SdkActivityRecording> startActivityRecording({
    required SdkActivitySession activitySession,
    String? deviceIdentity,
  });

  /// Explicitly binds a supported, verifiable TAG source to an unbound active
  /// recording. Repeating the same binding is idempotent; another TAG conflicts.
  /// Once bound, the identity is immutable for the recording. Switching TAG
  /// requires another recording lifecycle, never a display-name/list match.
  Future<SdkActivityRecording> bindActivityRecordingDevice({
    required String recordingId,
    required String deviceIdentity,
  });

  /// Requests/coalesces bounded retained-TAG-history reconciliation for the
  /// active recording. Unavailable recovery is deferred; disconnect is not a
  /// fatal recording error. Successful transfer does not prove completeness.
  /// Returns committed recording facts after that episode, not route arrays.
  Future<SdkActivityRecording> recoverActivityRecordingHistory({
    required String recordingId,
  });

  /// Fixes the cutoff before bounded final recovery and returns a committed
  /// finished result. Null [endedAt] uses recording-command acceptance time.
  /// An explicit cutoff cannot precede recording start or lie in the future.
  /// Unavailable/partial recovery preserves data and unresolved gap facts.
  ///
  /// A repeated finish of any retained matching ID returns its original result,
  /// never changes its cutoff and never finishes a different active recording.
  /// An absent ID fails with E_RECORDING_NOT_FOUND. Persistence failure cannot
  /// masquerade as a successful finish. The host separately orchestrates any
  /// logical session End and its DMP gate; this method does neither.
  Future<SdkActivityRecording> finishActivityRecording({
    required String recordingId,
    DateTime? endedAt,
  });

  /// Looks up an active/finalizing or retained finished recording by known ID
  /// within the current identity. Null means absent, not unreadable storage.
  /// Supports immediate-summary/crash recovery, not history browsing or listing.
  Future<SdkActivityRecording?> getActivityRecording({
    required String recordingId,
  });

  /// Finite paged read; all pages share one snapshot revision captured when
  /// listening. An empty route still yields one terminal page. Cancellation
  /// releases read resources; identity changes fence pending pages.
  ///
  /// [pageSize] must be positive and bounds points per page; a segment may span
  /// pages, retaining its ID. [fromInclusive] requests a replacement suffix,
  /// including gaps overlapping the boundary. Consumers must retain continuity
  /// across page fragments, not join across declared unreconciled gaps.
  ///
  /// A mismatched [expectedRouteRevision] fails before page delivery with
  /// E_RECORDING_ROUTE_REVISION_CHANGED (retryable via fresh state/read).
  /// This pages one known recording's route, never a list of activities.
  Stream<SdkActivityRoutePage> readActivityRecordingRoute({
    required String recordingId,
    DateTime? fromInclusive,
    int? expectedRouteRevision,
    int pageSize = 512,
  });
}
