import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:sqflite/sqflite.dart';

import 'activity_recording_record.dart';

/// Private exact ordering keys. Authoritative summaries remain in recordings.
/// All operations use the caller's transaction and never read route tables.
final class ActivityRecordingHistorySql {
  ActivityRecordingHistorySql(this.sql);
  final DatabaseExecutor sql;
  static const _batchSize = 256;
  static const _joined = '''SELECT r.*,
    h.recording_id AS history_id, h.owner_scope AS history_owner,
    h.ended_at_us AS history_end
    FROM recordings r LEFT JOIN recording_history_order h
    ON h.recording_id = r.recording_id''';
  // Keep orphan/invalid rows visible to validation; exclude only tombstones.
  static const _page = '''SELECT r.*,
    h.recording_id AS history_id, h.owner_scope AS history_owner,
    h.ended_at_us AS history_end
    FROM recording_history_order h INDEXED BY recording_history_page
    LEFT JOIN recordings r ON r.recording_id = h.recording_id
    WHERE h.owner_scope = ? AND r.is_deleted IS NOT 1''';
  static const _order =
      ' ORDER BY h.ended_at_us DESC, h.recording_id DESC LIMIT ?';

  static Future<void> create(DatabaseExecutor sql) async {
    await sql.execute('''CREATE TABLE recording_history_order (
      recording_id TEXT PRIMARY KEY NOT NULL
        REFERENCES recordings(recording_id) ON DELETE CASCADE,
      owner_scope TEXT NOT NULL,
      ended_at_us INTEGER NOT NULL
    )''');
    await sql.execute(
      '''CREATE INDEX recording_history_page
      ON recording_history_order(owner_scope, ended_at_us DESC, recording_id DESC)''',
    );
    await sql.execute('''CREATE INDEX recording_history_eligibility
      ON recordings(owner_scope, phase, ended_at)''');
    // Decode before eligibility filtering so unknown lifecycle values cannot
    // vanish during backfill. Existing Recording rows are never rewritten.
    await ActivityRecordingHistorySql(sql)._walk((row) async {
      final record = ActivityRecordingRecord.decode(row);
      if (record.value.phase == ActivityRecordingPhase.finished) {
        await sql.insert('recording_history_order', _entry(record));
      }
    });
  }

  static Map<String, Object?> _entry(ActivityRecordingRecord record) => {
    'recording_id': record.value.recordingId,
    'owner_scope': record.owner.scope,
    'ended_at_us': record.value.endedAt!.microsecondsSinceEpoch,
  };

  /// Never repairs inconsistent keys. A newly finished summary gets its entry
  /// in the same transaction; repeated finished writes require an existing match.
  Future<void> write(
    ActivityRecordingRecord record, {
    required bool wasFinished,
  }) => _checked(() async {
    final rows = await sql.query(
      'recording_history_order',
      where: 'recording_id = ?',
      whereArgs: [record.value.recordingId],
    );
    if (record.value.phase != ActivityRecordingPhase.finished) {
      if (wasFinished || rows.isNotEmpty) throw const FormatException();
      return;
    }
    if (rows.isEmpty) {
      if (wasFinished) throw const FormatException();
      await sql.insert('recording_history_order', _entry(record));
    } else {
      final expected = _entry(record);
      if (!wasFinished ||
          rows.length != 1 ||
          expected.entries.any((e) => rows.single[e.key] != e.value)) {
        throw const FormatException();
      }
    }
  }, persistenceWrite: true);

  Future<void> _walk(
    Future<void> Function(Map<String, Object?> row) visit,
  ) async {
    String? after;
    while (true) {
      final rows = await sql.rawQuery(
        '$_joined ${after == null ? '' : 'WHERE r.recording_id > ?'} '
        'ORDER BY r.recording_id LIMIT ?',
        [if (after != null) after, _batchSize],
      );
      for (final row in rows) {
        await visit(row);
      }
      if (rows.length < _batchSize) return;
      after = rows.last['recording_id'] as String;
    }
  }

  Future<void> prepare(String scope) => _checked(() async {
    await _walk((row) async {
      _decode(row, scope, allowUnfinished: true);
    });
    final invalid = await sql.rawQuery(
      '''SELECT 1
      FROM recording_history_order h LEFT JOIN recordings r
      ON r.recording_id = h.recording_id
      WHERE r.recording_id IS NULL OR h.owner_scope != ? LIMIT 1''',
      [scope],
    );
    if (invalid.isNotEmpty) throw const FormatException();
  });

  ActivityRecordingRecord _decode(
    Map<String, Object?> row,
    String scope, {
    bool allowUnfinished = false,
  }) {
    final record = ActivityRecordingRecord.decode(row);
    if (record.owner.scope != scope) throw const FormatException();
    if (record.value.phase != ActivityRecordingPhase.finished) {
      if (!allowUnfinished || row['history_id'] != null) {
        throw const FormatException();
      }
    } else if (row['history_id'] != record.value.recordingId ||
        row['history_owner'] != scope ||
        row['history_end'] is! int ||
        row['history_end'] != record.value.endedAt!.microsecondsSinceEpoch) {
      throw const FormatException();
    }
    return record;
  }

  /// Small index-range probes keep invalid lifecycle/null cutoffs from hiding
  /// behind a finished-only predicate, without scanning valid history per page.
  Future<void> _guard(String scope) async {
    // phase is NOT NULL in the schema. An IS NULL probe on that column makes
    // SQLite 3.8 scan the owner's index range instead of seeking a phase range.
    const predicates = [
      "phase < 'active'",
      "phase > 'active' AND phase < 'finalizing'",
      "phase > 'finalizing' AND phase < 'finished'",
      "phase > 'finished'",
      "phase = 'finished' AND ended_at IS NULL",
    ];
    final invalid = await sql.rawQuery(
      'SELECT 1 WHERE ${predicates.map((p) => 'EXISTS(SELECT 1 FROM recordings '
          'WHERE owner_scope = ? AND $p LIMIT 1)').join(' OR ')}',
      List.filled(predicates.length, scope),
    );
    if (invalid.isNotEmpty) throw const FormatException();
  }

  Future<List<ActivityRecordingRecord>> page(
    String scope, {
    required int limit,
    int? endedAtUs,
    String? recordingId,
  }) => _checked(() async {
    await _guard(scope);
    final List<Map<String, Object?>> rows;
    if (endedAtUs == null) {
      rows = await sql.rawQuery('$_page$_order', [scope, limit]);
    } else {
      rows = List.of(
        await sql.rawQuery(
          '$_page AND h.ended_at_us = ? AND h.recording_id < ?$_order',
          [scope, endedAtUs, recordingId, limit],
        ),
      );
      if (rows.length < limit) {
        rows.addAll(
          await sql.rawQuery('$_page AND h.ended_at_us < ?$_order', [
            scope,
            endedAtUs,
            limit - rows.length,
          ]),
        );
      }
    }
    return rows.map((row) => _decode(row, scope)).toList();
  });

  Future<T> _checked<T>(
    Future<T> Function() action, {
    bool persistenceWrite = false,
  }) async {
    try {
      return await action();
    } catch (error) {
      // Native write failures retain the database transaction's existing
      // E_RECORDING_PERSISTENCE_FAILED mapping; invalid stored facts fail closed.
      if (persistenceWrite && error is DatabaseException) rethrow;
      throw const ActivityRecordingException(
        'E_RECORDING_RESTORE_FAILED',
        'Recording storage is unreadable, corrupt, or uses an unsupported schema.',
      );
    }
  }
}
