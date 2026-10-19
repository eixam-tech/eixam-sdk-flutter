import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  test('unbound recording intent needs neither TAG nor distance', () {
    final recording = _recording();
    expect(recording.recordingId, 'recording-a');
    expect(recording.activitySessionId, 'session-a');
    expect(recording.recordingId, isNot(recording.activitySessionId));
    expect(recording.phase, ActivityRecordingPhase.active);
    expect(recording.inputState, ActivityRecordingInputState.unbound);
    expect(recording.deviceIdentity, isNull);
    expect(recording.endedAt, isNull);
    expect(recording.firstSampleAt, isNull);
    expect(recording.lastSampleAt, isNull);
    expect(recording.pointCount, 0);
    expect(recording.segmentCount, 0);
    expect(recording.unresolvedGapCount, 0);
    expect(recording.routeRevision, 0);
    expect(recording.previousRouteRevision, 0);
    expect(recording.routeChangedFrom, isNull);
  });

  test('bound disconnected intent is distinct from unbound intent', () {
    final recording = _recording(
      inputState: ActivityRecordingInputState.disconnected,
      deviceIdentity: 'opaque-tag',
    );
    expect(recording.phase, ActivityRecordingPhase.active);
    expect(recording.inputState, ActivityRecordingInputState.disconnected);
    expect(recording.deviceIdentity, 'opaque-tag');
    expect(recording.recordedDistanceMeters, isNull);
  });

  test('lifecycle, input, recovery and partial quality remain orthogonal', () {
    final recording = _recording(
      inputState: ActivityRecordingInputState.observing,
      recoveryState: ActivityRecordingRecoveryState.recovering,
      routeQuality: ActivityRecordingRouteQuality.partial,
      deviceIdentity: 'opaque-tag',
      issues: {ActivityRecordingIssue.recoveryFailed},
    );
    expect(recording.phase, ActivityRecordingPhase.active);
    expect(recording.inputState, ActivityRecordingInputState.observing);
    expect(recording.recoveryState, ActivityRecordingRecoveryState.recovering);
    expect(recording.routeQuality, ActivityRecordingRouteQuality.partial);
    expect(recording.lastSampleAt, isNull);
  });

  test('finalizing records carry their fixed cutoff', () {
    final cutoff = DateTime.utc(2026, 10, 19, 12);
    final recording = _recording(
      phase: ActivityRecordingPhase.finalizing,
      endedAt: cutoff,
      recoveryState: ActivityRecordingRecoveryState.deferred,
    );
    expect(recording.phase, ActivityRecordingPhase.finalizing);
    expect(recording.endedAt, cutoff);
    expect(recording.recoveryState, ActivityRecordingRecoveryState.deferred);
  });

  test('multiple finished results remain independently addressable by ID', () {
    final a = _recording(
      phase: ActivityRecordingPhase.finished,
      endedAt: DateTime.utc(2026, 10, 19, 12),
    );
    final b = _recording(
      recordingId: 'recording-b',
      sessionId: 'session-b',
      phase: ActivityRecordingPhase.finished,
      endedAt: DateTime.utc(2026, 10, 19, 13),
    );
    // Value fixtures only: no recorder, retention policy or store is simulated.
    final fixtures = {a.recordingId: a, b.recordingId: b};
    expect(fixtures, hasLength(2));
    expect(fixtures['recording-a'], same(a));
    expect(fixtures['recording-b'], same(b));
    expect(a.phase, ActivityRecordingPhase.finished);
    expect(b.phase, ActivityRecordingPhase.finished);
  });

  test(
    'all recording times normalize to UTC without conflating their roles',
    () {
      final activity = DateTime(2026, 10, 19, 9);
      final start = activity.add(const Duration(minutes: 5));
      final first = start.add(const Duration(seconds: 10));
      final last = first.add(const Duration(minutes: 2));
      final cutoff = last.add(const Duration(seconds: 20));
      final recording = SdkActivityRecording(
        recordingId: 'r',
        activitySessionId: 's',
        activityKey: 'org.example.paddling',
        activitySessionStartedAt: activity,
        recordingStartedAt: start,
        endedAt: cutoff,
        phase: ActivityRecordingPhase.finished,
        inputState: ActivityRecordingInputState.disconnected,
        recoveryState: ActivityRecordingRecoveryState.idle,
        routeQuality: ActivityRecordingRouteQuality.unknown,
        deviceIdentity: 'tag',
        pointCount: 2,
        segmentCount: 1,
        firstSampleAt: first,
        lastSampleAt: last,
        recordedDistanceMeters: 20,
        routeRevision: 3,
        previousRouteRevision: 2,
        routeChangedFrom: first,
      );
      final pairs = [
        (recording.activitySessionStartedAt, activity),
        (recording.recordingStartedAt, start),
        (recording.endedAt!, cutoff),
        (recording.firstSampleAt!, first),
        (recording.lastSampleAt!, last),
        (recording.routeChangedFrom!, first),
      ];
      for (final (actual, original) in pairs) {
        expect(actual.isUtc, isTrue);
        expect(actual, original.toUtc());
      }
      expect(
        recording.activitySessionStartedAt,
        isNot(recording.recordingStartedAt),
      );
      expect(recording.pointCount, 2);
      expect(recording.segmentCount, 1);
      expect(recording.recordedDistanceMeters, 20);
      expect(recording.routeRevision, 3);
      expect(recording.previousRouteRevision, 2);
    },
  );

  test('issue set is copied and cannot be changed through the model', () {
    final source = {ActivityRecordingIssue.clockUncertain};
    final recording = _recording(issues: source);
    source.clear();
    expect(recording.issues, {ActivityRecordingIssue.clockUncertain});
    expect(
      () => recording.issues.add(ActivityRecordingIssue.storageLimit),
      throwsUnsupportedError,
    );
    expect(() => recording.issues.clear(), throwsUnsupportedError);
  });

  for (final count in [0, 1]) {
    test('$count accepted points do not fabricate a distance', () {
      final recording = _recording(pointCount: count);
      expect(recording.recordedDistanceMeters, isNull);
    });
  }

  test('a genuine recorded zero is distinct from unavailable distance', () {
    final recording = _recording(pointCount: 2, distance: 0);
    expect(recording.recordedDistanceMeters, 0.0);
  });

  test('opaque extensible keys use the existing ActivitySession grammar', () {
    final recording = _recording();
    expect(recording.activityKey, 'org.example.paddling');
    expect(
      () => SdkActivitySession.validateActivityKey(recording.activityKey),
      returnsNormally,
    );
  });

  final enumNames = <String, (Iterable<Enum>, List<String>)>{
    'phase': (
      ActivityRecordingPhase.values,
      ['active', 'finalizing', 'finished'],
    ),
    'input': (
      ActivityRecordingInputState.values,
      ['unbound', 'disconnected', 'observing', 'unavailable'],
    ),
    'recovery': (
      ActivityRecordingRecoveryState.values,
      ['idle', 'recovering', 'deferred'],
    ),
    'quality': (ActivityRecordingRouteQuality.values, ['unknown', 'partial']),
    'gap state': (
      ActivityRecordingGapState.values,
      ['pending', 'recovering', 'unresolved', 'reconciled'],
    ),
    'gap reason': (
      ActivityRecordingGapReason.values,
      [
        'deviceUnavailable',
        'runtimeUnavailable',
        'rejectedSamples',
        'ambiguousTimestamp',
        'persistenceFailure',
      ],
    ),
    'issue': (
      ActivityRecordingIssue.values,
      [
        'deviceIdentityUnavailable',
        'commandOwnerUnavailable',
        'recoveryFailed',
        'recoveryTimedOut',
        'persistenceFailed',
        'invalidSamples',
        'clockUncertain',
        'storageLimit',
      ],
    ),
  };
  for (final entry in enumNames.entries) {
    test('${entry.key} enum names/order remain explicit', () {
      expect(entry.value.$1.map((value) => value.name), entry.value.$2);
    });
  }
}

SdkActivityRecording _recording({
  String recordingId = 'recording-a',
  String sessionId = 'session-a',
  ActivityRecordingPhase phase = ActivityRecordingPhase.active,
  ActivityRecordingInputState inputState = ActivityRecordingInputState.unbound,
  ActivityRecordingRecoveryState recoveryState =
      ActivityRecordingRecoveryState.idle,
  ActivityRecordingRouteQuality routeQuality =
      ActivityRecordingRouteQuality.unknown,
  String? deviceIdentity,
  DateTime? endedAt,
  Set<ActivityRecordingIssue> issues = const {},
  int pointCount = 0,
  double? distance,
}) => SdkActivityRecording(
  recordingId: recordingId,
  activitySessionId: sessionId,
  activityKey: 'org.example.paddling',
  activitySessionStartedAt: DateTime.utc(2026, 10, 19, 9),
  recordingStartedAt: DateTime.utc(2026, 10, 19, 9, 5),
  endedAt: endedAt,
  deviceIdentity: deviceIdentity ?? (pointCount > 0 ? 'opaque-tag' : null),
  phase: phase,
  inputState: pointCount > 0
      ? ActivityRecordingInputState.observing
      : inputState,
  recoveryState: recoveryState,
  routeQuality: routeQuality,
  issues: issues,
  pointCount: pointCount,
  segmentCount: pointCount > 0 ? 1 : 0,
  firstSampleAt: pointCount > 0 ? DateTime.utc(2026, 10, 19, 9, 5, 10) : null,
  lastSampleAt: pointCount > 0
      ? DateTime.utc(2026, 10, 19, 9, 5, pointCount > 1 ? 20 : 10)
      : null,
  recordedDistanceMeters: distance,
);
