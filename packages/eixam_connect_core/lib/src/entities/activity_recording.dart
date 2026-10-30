import '../enums/activity_recording.dart';
import 'activity_session.dart';

/// Immutable local TAG-recording facts, without route arrays or safety ownership.
///
/// AR1 defines value models only; no production recorder or storage is provided.
/// Constructors normalize timestamps and copy collections. Runtime validation,
/// lifecycle transitions and durable identity isolation belong to the recorder.
final class SdkActivityRecording {
  SdkActivityRecording({
    required this.recordingId,
    required this.activitySessionId,
    required this.activityKey,
    required DateTime activitySessionStartedAt,
    required DateTime recordingStartedAt,
    required this.phase,
    required this.inputState,
    required this.recoveryState,
    required this.routeQuality,
    DateTime? endedAt,
    this.deviceIdentity,
    Set<ActivityRecordingIssue> issues = const {},
    this.pointCount = 0,
    this.segmentCount = 0,
    this.unresolvedGapCount = 0,
    DateTime? firstSampleAt,
    DateTime? lastSampleAt,
    this.recordedDistanceMeters,
    this.routeRevision = 0,
    this.previousRouteRevision = 0,
    DateTime? routeChangedFrom,
  }) : activitySessionStartedAt = activitySessionStartedAt.toUtc(),
       recordingStartedAt = recordingStartedAt.toUtc(),
       endedAt = endedAt?.toUtc(),
       issues = Set.unmodifiable(issues),
       firstSampleAt = firstSampleAt?.toUtc(),
       lastSampleAt = lastSampleAt?.toUtc(),
       routeChangedFrom = routeChangedFrom?.toUtc();

  /// Local recording-domain ID, independent of [activitySessionId].
  /// The recorder will generate secure random IDs; this model generates none.
  final String recordingId;

  /// Explicit association; never changes the logical session's lifecycle.
  final String activitySessionId;

  /// Opaque activity key following [SdkActivitySession.validateActivityKey].
  /// No activity catalog, partner interpretation or second grammar is implied.
  final String activityKey;

  /// Logical activity start copied from the associated session, not a new timer.
  final DateTime activitySessionStartedAt;

  /// Recording acceptance/persistence window start, potentially after activity
  /// start. Waiting for a TAG does not shift this timestamp.
  final DateTime recordingStartedAt;

  /// Fixed recording cutoff for finalizing/finished results; null while active.
  /// Does not expose the ActivitySession's private end timestamp.
  final DateTime? endedAt;

  /// Opaque verified TAG identity; null until explicitly bound, then immutable
  /// for the recording. It is not a display name or a BLE list position.
  /// Supports a legacy canonical MAC or `node:<decimal>` registered-node source;
  /// this Recording-specific encoding does not redefine device hardware IDs.
  final String? deviceIdentity;

  final ActivityRecordingPhase phase;
  final ActivityRecordingInputState inputState;
  final ActivityRecordingRecoveryState recoveryState;
  final ActivityRecordingRouteQuality routeQuality;
  final Set<ActivityRecordingIssue> issues;

  /// Counts across the full canonical recording, not a route-page fragment.
  final int pointCount;
  final int segmentCount;
  final int unresolvedGapCount;

  /// Earliest/latest accepted TAG sample times; their span is not moving time
  /// or proof of continuously recorded duration.
  final DateTime? firstSampleAt;
  final DateTime? lastSampleAt;

  /// Recorded horizontal TAG route distance, not exact physical movement.
  /// Null means no defensible distance edge exists, including empty/one-point
  /// routes. A genuine zero requires eligible edges that total zero.
  /// Distance excludes unreconciled gaps and altitude contribution.
  final double? recordedDistanceMeters;

  /// Local canonical-route revision, not a cloud or server revision.
  /// Zero represents the initial route; route/gap mutations advance it.
  final int routeRevision;

  /// Revision immediately preceding the most recent canonical-route mutation.
  /// Consumers that missed that base must refresh rather than merge a suffix.
  final int previousRouteRevision;

  /// Earliest affected sample/gap time between [previousRouteRevision] and
  /// [routeRevision], inclusive. Null for the initial unchanged route.
  /// Metadata-only observations do not describe another route mutation.
  final DateTime? routeChangedFrom;
}
