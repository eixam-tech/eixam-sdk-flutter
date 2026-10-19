import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:sqflite/sqflite.dart';

import 'activity_recording_record.dart';
import 'activity_recording_integrity.dart';
import 'activity_recording_route_data.dart';
import 'activity_recording_route_sql.dart';

/// Gap changes and their distance/topology repair share the caller's transaction.
final class ActivityRecordingRecoverySql {
  ActivityRecordingRecoverySql(this.sql);
  final DatabaseExecutor sql;

  Future<void> need(ActivityRecordingRecord record) async {
    await ActivityRecordingIntegrity.gaps(sql, record);
    await ActivityRecordingIntegrity.recovery(sql, record);
    await sql.insert('recording_recovery', {
      'recording_id': record.value.recordingId,
      'needed': 1,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await sql.update(
      'recording_recovery',
      {'needed': 1},
      where: 'recording_id = ?',
      whereArgs: [record.value.recordingId],
    );
  }

  Future<ActivityRecordingRecoveryWindow> window(
    ActivityRecordingRecord record,
  ) async {
    final row = await ActivityRecordingIntegrity.recovery(sql, record);
    final gaps = await ActivityRecordingIntegrity.gaps(sql, record);
    final unresolved = gaps.where(
      (gap) => gap['state'] != ActivityRecordingGapState.reconciled.name,
    );
    final earliest = unresolved.isEmpty
        ? null
        : unresolved.first['from_order'] as int;
    final cursor = row?['processed_through'] as int?;
    // A new live tail must never skip an older unresolved interval. Re-request
    // the boundary inclusively; the durable route ledger removes replays.
    final since = earliest != null && (cursor == null || earliest < cursor)
        ? earliest
        : cursor;
    return ActivityRecordingRecoveryWindow(
      since == null
          ? record.value.recordingStartedAt
          : DateTime.fromMicrosecondsSinceEpoch(since, isUtc: true),
      earliest != null || row?['needed'] == 1,
    );
  }

  Future<ActivityRecordingRecord> inputPath(
    ActivityRecordingRecord record,
    bool connected,
    DateTime now,
  ) async {
    final r = record.value;
    final id = r.recordingId;
    final allGaps = await ActivityRecordingIntegrity.gaps(sql, record);
    await ActivityRecordingIntegrity.recovery(sql, record);
    final open = allGaps
        .where(
          (gap) =>
              gap['reason'] ==
                  ActivityRecordingGapReason.deviceUnavailable.name &&
              gap['until_order'] == null &&
              gap['state'] != ActivityRecordingGapState.reconciled.name,
        )
        .toList();
    int? changed;
    if (!connected && open.isEmpty) {
      final from = r.lastSampleAt ?? r.recordingStartedAt;
      changed = from.microsecondsSinceEpoch;
      await sql.insert('route_gaps', {
        'gap_id': '$id:disconnect:${r.routeRevision}',
        'recording_id': id,
        'from_time': from.toIso8601String(),
        'from_order': changed,
        'reason': ActivityRecordingGapReason.deviceUnavailable.name,
        'state': ActivityRecordingGapState.pending.name,
      });
      await need(record);
    } else if (connected && open.isNotEmpty) {
      for (final row in open) {
        final from = row['from_order'] as int;
        final end = now.toUtc().microsecondsSinceEpoch;
        if (end < from) {
          continue; // No invented boundary after a clock rollback.
        }
        await sql.update(
          'route_gaps',
          {'until_time': now.toUtc().toIso8601String(), 'until_order': end},
          where: 'gap_id = ?',
          whereArgs: [row['gap_id']],
        );
        if (changed == null || from < changed) changed = from;
      }
    }
    final updated = record.transition(
      inputState: connected
          ? ActivityRecordingInputState.observing
          : ActivityRecordingInputState.disconnected,
      recoveryState: !connected
          ? ActivityRecordingRecoveryState.deferred
          : null,
    );
    if (changed != null) {
      return ActivityRecordingRouteSql(sql).ingest(
        updated,
        const [],
        topologyChangedFrom: changed,
        topologyChangedUntil: connected
            ? now.toUtc().microsecondsSinceEpoch
            : null,
      );
    }
    await sql.update(
      'recordings',
      updated.encode(),
      where: 'recording_id = ?',
      whereArgs: [id],
    );
    return updated;
  }

  /// `completed` means every D1 logical index and END validated, and every
  /// delivered in-window sample committed without rejection or identity conflict.
  /// Even that proves no coverage without retained samples at BOTH boundaries.
  Future<ActivityRecordingRecord> settle(
    ActivityRecordingRecord record, {
    required bool completed,
    DateTime? first,
    DateTime? last,
  }) async {
    final id = record.value.recordingId;
    final allGaps = await ActivityRecordingIntegrity.gaps(sql, record);
    await ActivityRecordingIntegrity.recovery(sql, record);
    final gaps = allGaps
        .where(
          (gap) =>
              gap['reason'] ==
                  ActivityRecordingGapReason.deviceUnavailable.name &&
              gap['state'] != ActivityRecordingGapState.reconciled.name,
        )
        .toList();
    int? changedUntil;
    int? changed;
    for (final gap in gaps) {
      final from = gap['from_order'] as int;
      final until = gap['until_order'] as int?;
      final integrity = await sql.rawQuery(
        """SELECT 1 FROM route_gaps
        WHERE recording_id = ? AND reason != 'deviceUnavailable' AND state != 'reconciled'
        AND from_order <= ? AND (until_order IS NULL OR until_order >= ?) LIMIT 1""",
        [id, until ?? 9223372036854775807, from],
      );
      final proved =
          integrity.isEmpty &&
          completed &&
          first != null &&
          last != null &&
          until != null &&
          first.microsecondsSinceEpoch <= from &&
          last.microsecondsSinceEpoch >= until &&
          first.isBefore(last);
      final state = proved
          ? ActivityRecordingGapState.reconciled
          : ActivityRecordingGapState.unresolved;
      if (gap['state'] == state.name) continue;
      await sql.update(
        'route_gaps',
        {'state': state.name},
        where: 'gap_id = ?',
        whereArgs: [gap['gap_id']],
      );
      if (changed == null || from < changed) changed = from;
      // Pending/unresolved both block the same edges. Only reconciliation
      // changes downstream topology; a state-only change needs local context.
      if (proved && (changedUntil == null || until > changedUntil)) {
        changedUntil = until;
      }
    }
    final remaining = Sqflite.firstIntValue(
      await sql.rawQuery(
        "SELECT COUNT(*) FROM route_gaps WHERE recording_id = ? AND state != 'reconciled'",
        [id],
      ),
    )!;
    // Use the same portable INSERT OR IGNORE + UPDATE pattern as the store;
    // recording recovery must not require a newer platform SQLite UPSERT.
    await sql.insert('recording_recovery', {
      'recording_id': id,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    final cursor = completed ? last?.microsecondsSinceEpoch : null;
    await sql.rawUpdate(
      '''UPDATE recording_recovery SET
      processed_through = CASE WHEN ? IS NULL THEN processed_through
        WHEN processed_through IS NULL THEN ? ELSE MAX(processed_through, ?) END,
      needed = ? WHERE recording_id = ?''',
      [cursor, cursor, cursor, !completed || remaining > 0 ? 1 : 0, id],
    );
    final updated = record.transition(
      recoveryState: completed && remaining == 0
          ? ActivityRecordingRecoveryState.idle
          : ActivityRecordingRecoveryState.deferred,
    );
    if (changed != null) {
      return ActivityRecordingRouteSql(sql).ingest(
        updated,
        const [],
        topologyChangedFrom: changed,
        topologyChangedUntil: changedUntil ?? changed,
      );
    }
    await sql.update(
      'recordings',
      updated.encode(),
      where: 'recording_id = ?',
      whereArgs: [id],
    );
    return updated;
  }
}
