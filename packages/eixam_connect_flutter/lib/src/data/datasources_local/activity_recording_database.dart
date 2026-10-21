import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:sqflite/sqflite.dart';

import 'activity_recording_record.dart';
import 'activity_recording_history_sql.dart';
import 'activity_recording_integrity.dart';
import 'activity_recording_route_data.dart';
import 'activity_recording_route_sql.dart';
import 'activity_recording_recovery_sql.dart';
import 'activity_recording_schema.dart';
import 'activity_recording_store.dart';
import 'activity_recording_storage_directory.dart';

/// SDK-private SQLite store. Native preparation establishes no-backup storage
/// before any default-path SQLite open. Does not provide database encryption.
final class ActivityRecordingDatabase implements ActivityRecordingStore {
  ActivityRecordingDatabase({
    String? path,
    DatabaseFactory? factory,
    Future<Directory> Function()? directory,
    ActivityRecordingStorageDirectory storageDirectory =
        const ActivityRecordingStorageDirectory(),
  }) : _configuredPath = path,
       _factory = factory,
       _directory = directory,
       _storageDirectory = storageDirectory;

  final String? _configuredPath;
  final DatabaseFactory? _factory;
  // Explicit path/directory overrides are private test seams only.
  final Future<Directory> Function()? _directory;
  final ActivityRecordingStorageDirectory _storageDirectory;
  Database? _database;
  bool _disposed = false;

  @override
  Object get writerNamespace =>
      _configuredPath ?? 'eixam.activity.recordings.v1';

  Future<String> _path() async {
    if (_configuredPath case final path?) return path;
    if (_directory case final directory?) {
      return '${(await directory()).path}/eixam/activity_recordings/recordings.sqlite';
    }
    return '${(await _storageDirectory.prepare()).path}/recordings.sqlite';
  }

  Future<Database> _open() async {
    if (_disposed) throw _unavailable;
    if (_database case final db?) return db;
    try {
      final path = await _path();
      final db = await (_factory ?? databaseFactory).openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: ActivityRecordingSchema.version,
          singleInstance: false,
          onConfigure: (db) async {
            await db.execute('PRAGMA foreign_keys = ON');
            await db.rawQuery('PRAGMA journal_mode = WAL');
            await db.execute('PRAGMA synchronous = FULL');
          },
          onCreate: ActivityRecordingSchema.create,
          onUpgrade: ActivityRecordingSchema.upgrade,
          onDowngrade: (_, _, _) async => throw _restoreFailed,
        ),
      );
      if (_disposed) {
        await db.close();
        throw _unavailable;
      }
      _database = db;
      return db;
    } on ActivityRecordingException {
      rethrow;
    } catch (_) {
      // Never expose SQLite messages, SQL arguments, paths or identity payloads.
      throw _restoreFailed;
    }
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(ActivityRecordingTransaction tx) action,
  ) async {
    final db = await _open();
    try {
      return await db.transaction((tx) => action(_SqlRecordingTransaction(tx)));
    } on ActivityRecordingException {
      rethrow;
    } catch (_) {
      throw _persistenceFailed;
    }
  }

  @override
  Future<void> clear() async {
    if (_disposed) throw _unavailable;
    // Identity-only use does not create an empty database or require SQLite.
    try {
      if (_database == null && !await File(await _path()).exists()) return;
    } catch (_) {
      throw _persistenceFailed;
    }
    await transaction((tx) async {
      final sql = (tx as _SqlRecordingTransaction).sql;
      // Explicitly remove every table even if corrupt legacy rows lack FKs.
      await sql.delete('recording_history_order');
      await sql.delete('recording_recovery');
      await sql.delete('route_points');
      await sql.delete('route_gaps');
      await sql.delete('recordings');
      await sql.delete('recording_store_metadata');
    });
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final db = _database;
    _database = null;
    await db?.close();
  }
}

final class _SqlRecordingTransaction implements ActivityRecordingTransaction {
  _SqlRecordingTransaction(this.sql);
  final Transaction sql;

  @override
  Future<bool> reconcileOwner(ActivityRecordingOwner owner) async {
    final rows = await sql.query('recording_store_metadata');
    if (rows.length > 1) throw _restoreFailed;
    var conflict = false;
    var sameOwner = false;
    if (rows.isNotEmpty) {
      final row = rows.single;
      if (row['singleton'] != 1 ||
          row['owner_scope'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(row['owner_scope'] as String) ||
          (row['sdk_user_id'] != null && row['sdk_user_id'] is! String) ||
          (row['canonical_user_id'] != null &&
              row['canonical_user_id'] is! String)) {
        throw _restoreFailed;
      }
      final old = ActivityRecordingOwner(
        row['owner_scope'] as String,
        row['sdk_user_id'] as String?,
        row['canonical_user_id'] as String?,
      );
      final foreignRows = await sql.rawQuery(
        'SELECT 1 FROM recordings WHERE owner_scope != ? LIMIT 1',
        [old.scope],
      );
      if (foreignRows.isNotEmpty) throw _restoreFailed;
      sameOwner = old.scope == owner.scope;
      conflict = old.scope == owner.scope && old.conflicts(owner);
      if (old.scope != owner.scope || conflict) {
        await sql.delete('recording_history_order');
        await sql.delete('recording_recovery');
        await sql.delete('route_points');
        await sql.delete('route_gaps');
        await sql.delete('recordings');
      }
    } else {
      final count = Sqflite.firstIntValue(
        await sql.rawQuery('SELECT COUNT(*) FROM recordings'),
      );
      if (count != 0 ||
          (await sql.query('recording_history_order', limit: 1)).isNotEmpty) {
        throw _restoreFailed;
      }
    }
    await sql.insert('recording_store_metadata', {
      'singleton': 1,
      'owner_scope': owner.scope,
      'sdk_user_id':
          owner.sdkUserId ??
          (sameOwner && !conflict ? rows.single['sdk_user_id'] : null),
      'canonical_user_id':
          owner.canonicalUserId ??
          (sameOwner && !conflict ? rows.single['canonical_user_id'] : null),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return conflict;
  }

  @override
  Future<void> prepareHistory(String scope) =>
      ActivityRecordingHistorySql(sql).prepare(scope);

  @override
  Future<List<ActivityRecordingRecord>> finishedHistory(
    String scope, {
    required int limit,
    int? endedAtUs,
    String? recordingId,
  }) => ActivityRecordingHistorySql(
    sql,
  ).page(scope, limit: limit, endedAtUs: endedAtUs, recordingId: recordingId);

  Future<ActivityRecordingRecord?> _read(
    String where,
    List<Object?> args,
  ) async {
    try {
      final rows = await sql.query(
        'recordings',
        where: where,
        whereArgs: args,
        limit: 2,
      );
      if (rows.length > 1) throw _restoreFailed;
      if (rows.isEmpty) return null;
      final record = ActivityRecordingRecord.decode(rows.single);
      await ActivityRecordingIntegrity.gaps(sql, record);
      await ActivityRecordingIntegrity.recovery(sql, record);
      // The primary key makes the proven empty-key guard independent of route size.
      final invalidKey = await sql.query(
        'route_points',
        columns: ['sample_key'],
        where: "recording_id = ? AND sample_key = ''",
        whereArgs: [record.value.recordingId],
        limit: 1,
      );
      if (invalidKey.isNotEmpty) throw const FormatException();
      return record;
    } catch (_) {
      throw _restoreFailed;
    }
  }

  @override
  Future<ActivityRecordingRecord?> active(String scope) async {
    // Unknown lifecycle values must not disappear behind the active predicate.
    final invalid = await sql.rawQuery(
      '''SELECT 1 FROM recordings WHERE owner_scope = ?
      AND phase NOT IN ('active','finalizing','finished') LIMIT 1''',
      [scope],
    );
    if (invalid.isNotEmpty) throw _restoreFailed;
    return _read("owner_scope = ? AND phase IN ('active','finalizing')", [
      scope,
    ]);
  }

  @override
  Future<ActivityRecordingRecord?> byId(
    String scope,
    String id, {
    bool includeDeleted = false,
  }) => _read(
    'owner_scope = ? AND recording_id = ?${includeDeleted ? '' : ' AND is_deleted IS NOT 1'}',
    [scope, id],
  );

  @override
  Future<ActivityRecordingRecord?> forSession(String scope, String id) =>
      _read('owner_scope = ? AND activity_session_id = ?', [scope, id]);

  @override
  Future<void> insert(ActivityRecordingRecord record) async {
    await sql.insert('recordings', record.encode());
    await ActivityRecordingHistorySql(sql).write(record, wasFinished: false);
  }

  @override
  Future<void> update(ActivityRecordingRecord record) async {
    final previous = await sql.query(
      'recordings',
      columns: ['phase'],
      where: 'owner_scope = ? AND recording_id = ?',
      whereArgs: [record.owner.scope, record.value.recordingId],
    );
    final changed = await sql.update(
      'recordings',
      record.encode(),
      where: 'owner_scope = ? AND recording_id = ?',
      whereArgs: [record.owner.scope, record.value.recordingId],
    );
    if (changed != 1) throw _persistenceFailed;
    await ActivityRecordingHistorySql(
      sql,
    ).write(record, wasFinished: previous.single['phase'] == 'finished');
  }

  @override
  Future<ActivityRecordingRecord> finishRoute(
    ActivityRecordingRecord record,
    DateTime cutoff,
  ) => ActivityRecordingRouteSql(sql).finish(record, cutoff);

  @override
  Future<ActivityRecordingRecord> ingestRoute(
    ActivityRecordingRecord record,
    List<ActivityRecordingRouteEvidence> evidence,
  ) => ActivityRecordingRouteSql(sql).ingest(record, evidence);

  @override
  Future<ActivityRecordingRecord> inputPath(
    ActivityRecordingRecord record,
    bool connected,
    DateTime now,
  ) => ActivityRecordingRecoverySql(sql).inputPath(record, connected, now);

  @override
  Future<ActivityRecordingRecoveryWindow> recoveryWindow(
    ActivityRecordingRecord record,
  ) => ActivityRecordingRecoverySql(sql).window(record);

  @override
  Future<void> needRecovery(ActivityRecordingRecord record) =>
      ActivityRecordingRecoverySql(sql).need(record);

  @override
  Future<ActivityRecordingRecord> settleRecovery(
    ActivityRecordingRecord record, {
    required bool completed,
    DateTime? first,
    DateTime? last,
  }) => ActivityRecordingRecoverySql(
    sql,
  ).settle(record, completed: completed, first: first, last: last);

  @override
  Future<ActivityRecordingRouteSlice> routePage(
    ActivityRecordingRecord record, {
    DateTime? fromInclusive,
    ActivityRecordingRouteCursor? after,
    required int pageSize,
  }) => ActivityRecordingRouteSql(sql).page(
    record,
    fromInclusive: fromInclusive,
    after: after,
    pageSize: pageSize,
  );

  @override
  Future<void> verifyEmptyRoute(String recordingId) async {
    final counts = await sql.rawQuery(
      '''SELECT
      (SELECT COUNT(*) FROM route_points WHERE recording_id = ?) +
      (SELECT COUNT(*) FROM route_gaps WHERE recording_id = ?) AS n''',
      [recordingId, recordingId],
    );
    if (counts.single['n'] != 0) throw _restoreFailed;
  }
}

const _restoreFailed = ActivityRecordingException(
  'E_RECORDING_RESTORE_FAILED',
  'Recording storage is unreadable, corrupt, or uses an unsupported schema.',
);
const _persistenceFailed = ActivityRecordingException(
  'E_RECORDING_PERSISTENCE_FAILED',
  'Recording storage could not commit the operation. Reconcile before retrying.',
);
const _unavailable = ActivityRecordingException(
  'E_RECORDING_UNAVAILABLE',
  'Recording storage is unavailable or disposed.',
);
