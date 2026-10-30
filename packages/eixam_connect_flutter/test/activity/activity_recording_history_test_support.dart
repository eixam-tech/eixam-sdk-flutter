import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_record.dart';
import 'package:sqflite/sqflite.dart';

import 'recording_test_support.dart';

String historyId(int n) => n.toRadixString(16).padLeft(32, '0');

ActivityRecordingRecord historyRecord(
  RecordingFixture f,
  int n, {
  DateTime? end,
  ActivityRecordingPhase phase = ActivityRecordingPhase.finished,
  bool partial = false,
}) {
  final at = end ?? f.now;
  final start = at.subtract(const Duration(minutes: 1));
  return ActivityRecordingRecord(
    ActivityRecordingOwner.forIdentity(f.backend, f.user!),
    SdkActivityRecording(
      recordingId: historyId(n),
      activitySessionId: 'history-$n',
      activityKey: 'org.example.paddle',
      activitySessionStartedAt: start,
      recordingStartedAt: start,
      endedAt: phase == ActivityRecordingPhase.active ? null : at,
      phase: phase,
      inputState: ActivityRecordingInputState.unbound,
      recoveryState: ActivityRecordingRecoveryState.idle,
      routeQuality: partial
          ? ActivityRecordingRouteQuality.partial
          : ActivityRecordingRouteQuality.unknown,
      unresolvedGapCount: partial ? 1 : 0,
      routeRevision: partial ? 1 : 0,
      routeChangedFrom: partial ? start : null,
      issues: partial ? {ActivityRecordingIssue.recoveryFailed} : {},
    ),
  );
}

Future<void> seedHistory(
  RecordingFixture f,
  Iterable<ActivityRecordingRecord> records,
) => f.database.transaction((tx) async {
  await tx.reconcileOwner(
    ActivityRecordingOwner.forIdentity(f.backend, f.user!),
  );
  for (final record in records) {
    await tx.insert(record);
  }
});

/// Tests the actual SQL boundary, rejecting any route or recovery-table access.
final class HistoryQueryTrace implements DatabaseExecutor {
  HistoryQueryTrace(this.inner);
  final DatabaseExecutor inner;
  final queries = <(String, List<Object?>?)>[];
  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) {
    if (RegExp(r'route_points|route_gaps|recording_recovery').hasMatch(sql)) {
      throw StateError('History accessed route storage');
    }
    queries.add((sql, arguments));
    return inner.rawQuery(sql, arguments);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
