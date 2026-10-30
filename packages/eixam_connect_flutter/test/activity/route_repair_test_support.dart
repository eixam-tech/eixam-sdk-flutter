import 'dart:convert';
import 'dart:collection';
import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'recording_test_support.dart';
import 'activity_recording_ingestion_test.dart' show sample, batch;

void report(String kind, Map<String, Object?> data) =>
    debugPrint('AR2D ${jsonEncode({'kind': kind, ...data})}');
Future<int> timed(Future<void> Function() f) async {
  final s = Stopwatch()..start();
  await f();
  return s.elapsedMicroseconds;
}

Future<SdkActivityRecording> seed(RecordingFixture f, int n) async {
  final r = await f.start(device: tagA);
  final start = r.recordingStartedAt;
  for (var i = 0; i < n; i += 512) {
    final end = (i + 512 < n ? i + 512 : n);
    f.now = start.add(Duration(seconds: end * 2 + 1));
    await f.controller.ingestLive(
      batch(f, [
        for (var j = i; j < end; j++)
          sample(
            j.toRadixString(16).padLeft(64, '0'),
            start.add(Duration(seconds: j * 2)),
            latitude: 41 + j / 1e7,
            longitude: 2 + j / 1e7,
          ),
      ]),
    );
  }
  return (await f.controller.getActiveActivityRecording())!;
}

class Spy implements DatabaseExecutor {
  Spy(this.inner);
  final DatabaseExecutor inner;
  final counts = <String, int>{};
  final micros = <String, int>{};
  Future<T> track<T>(String op, Future<T> Function() action) async {
    final s = Stopwatch()..start();
    try {
      return await action();
    } finally {
      counts.update(op, (n) => n + 1, ifAbsent: () => 1);
      micros.update(
        op,
        (n) => n + s.elapsedMicroseconds,
        ifAbsent: () => s.elapsedMicroseconds,
      );
    }
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => track(
    'query:$table',
    () => inner.query(
      table,
      distinct: distinct,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      groupBy: groupBy,
      having: having,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    ),
  );
  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? args,
  ]) => track('rawQuery', () => inner.rawQuery(sql, args));
  @override
  Future<int> rawUpdate(String sql, [List<Object?>? args]) =>
      track('rawUpdate', () => inner.rawUpdate(sql, args));
  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) => track(
    'insert:$table',
    () => inner.insert(
      table,
      values,
      nullColumnHack: nullColumnHack,
      conflictAlgorithm: conflictAlgorithm,
    ),
  );
  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) => track(
    'update:$table',
    () => inner.update(
      table,
      values,
      where: where,
      whereArgs: whereArgs,
      conflictAlgorithm: conflictAlgorithm,
    ),
  );
  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      track(
        'delete:$table',
        () => inner.delete(table, where: where, whereArgs: whereArgs),
      );
  @override
  Batch batch() => inner.batch();
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class BatchSpy implements Batch {
  BatchSpy(this.inner, this.updates);
  final Batch inner;
  final List<Map<String, Object?>> updates;
  @override
  void update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    updates.add({'table': table, ...values});
    inner.update(
      table,
      values,
      where: where,
      whereArgs: whereArgs,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

  @override
  Future<List<Object?>> commit({
    bool? exclusive,
    bool? noResult,
    bool? continueOnError,
  }) => inner.commit(
    exclusive: exclusive,
    noResult: noResult,
    continueOnError: continueOnError,
  );
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class ProfileSpy extends Spy {
  ProfileSpy(super.inner);
  final updates = <Map<String, Object?>>[];
  final queries = <Map<String, Object?>>[];
  int repairRowsInspected = 0;
  int get pointRowsFetched => queries
      .where((q) => q['table'] == 'route_points')
      .fold(0, (n, q) => n + (q['rows'] as int));
  @override
  Batch batch() => BatchSpy(inner.batch(), updates);
  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    final rows = await super.query(
      table,
      distinct: distinct,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      groupBy: groupBy,
      having: having,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
    queries.add({
      'table': table,
      'where': where,
      'rows': rows.length,
      'from': whereArgs?.length == 2 ? whereArgs![1] : null,
    });
    if (table == 'route_points' &&
        columns == null &&
        where?.contains('sample_order >=') == true) {
      return [
        for (final row in rows) _InspectedRow(row, () => repairRowsInspected++),
      ];
    }
    return rows;
  }
}

/// Counts consumed repair rows, independently of SQL prefetch and implementation.
final class _InspectedRow extends MapBase<String, Object?> {
  _InspectedRow(this.inner, this.inspect);
  final Map<String, Object?> inner;
  final void Function() inspect;
  bool seen = false;
  @override
  Object? operator [](Object? key) {
    if (key == 'sample_key' && !seen) {
      seen = true;
      inspect();
    }
    return inner[key];
  }

  @override
  Iterable<String> get keys => inner.keys;
  @override
  void operator []=(String key, Object? value) =>
      throw UnsupportedError('read only');
  @override
  Object? remove(Object? key) => throw UnsupportedError('read only');
  @override
  void clear() => throw UnsupportedError('read only');
}
