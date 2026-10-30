import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_record.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_route_sql.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'activity_recording_ingestion_test.dart' show batch, sample;
import 'recording_test_support.dart';
import 'route_repair_test_support.dart' show Spy, seed;

final integrityError = isA<ActivityRecordingException>().having(
  (e) => e.code,
  'sanitized integrity error',
  isIn(['E_RECORDING_PERSISTENCE_FAILED', 'E_RECORDING_RESTORE_FAILED']),
);

Future<Map<String, List<Map<String, Object?>>>> snapshot(Database db) async => {
  for (final table in [
    'recordings',
    'route_points',
    'route_gaps',
    'recording_recovery',
  ])
    table: await db.query(table, orderBy: 'rowid'),
};

void main() {
  for (final corruption in ['negative-edge', 'malformed-tail']) {
    test(
      'Finish rejects $corruption before clipping and preserves evidence',
      () async {
        final f = await RecordingFixture.create();
        final observed = <SdkActivityRecording?>[];
        final errors = <Object>[];
        final watch = f.controller.watchActiveActivityRecording().listen(
          observed.add,
          onError: errors.add,
        );
        try {
          final r = await f.start(device: tagA);
          f.now = f.now.add(const Duration(seconds: 10));
          await f.controller.ingestLive(
            batch(f, [
              for (var i = 0; i < 4; i++)
                sample(
                  'p$i',
                  r.recordingStartedAt.add(Duration(seconds: i)),
                  longitude: 1 + i.toDouble(),
                ),
            ]),
          );
          await f.controller.inputDisconnected(tagA, false);
          await f.controller.inputDisconnected(tagA, true);
          await pumpEventQueue();
          final db = await f.raw();
          try {
            await db.update(
              'route_points',
              corruption == 'negative-edge'
                  ? {'edge_distance': -1}
                  : {'sampled_at': 'malformed'},
              where: 'sample_key = ?',
              whereArgs: [corruption == 'negative-edge' ? 'p1' : 'p3'],
            );
            final before = await snapshot(db);
            final emissions = observed.length;
            final cutoff = r.recordingStartedAt.add(const Duration(seconds: 2));
            for (var retry = 0; retry < 2; retry++) {
              await expectLater(
                f.controller.finishActivityRecording(
                  recordingId: r.recordingId,
                  endedAt: cutoff,
                ),
                throwsA(integrityError),
              );
              await pumpEventQueue();
              expect(await snapshot(db), before);
              expect(observed.length, emissions);
              expect(observed.last!.phase, ActivityRecordingPhase.active);
            }
          } finally {
            await db.close();
          }
        } finally {
          await watch.cancel();
          await f.delete();
        }
      },
    );
  }

  for (final clipped in [false, true]) {
    for (final invalid in <String, Map<String, Object?>>{
      'time': {'sampled_at': 'malformed'},
      'canonical-time': {'sampled_at': '2026-10-19T12:00:00Z'},
      'order': {'sample_order': -1},
      'coordinates': {'latitude': 1000},
      'provenance': {'delivery': 'unsupported'},
      'device': {'device_identity': tagB},
      'previous-key': {'previous_key': ''},
      'edge-type': {'edge_distance': 'malformed'},
      'altitude': {'altitude_meters': 'malformed'},
    }.entries) {
      test(
        'full point validation rejects ${invalid.key} clipped=$clipped',
        () async {
          final f = await RecordingFixture.create();
          try {
            final r = await f.start(device: tagA);
            f.now = f.now.add(const Duration(seconds: 10));
            await f.controller.ingestLive(
              batch(f, [
                for (var i = 0; i < 4; i++)
                  sample('p$i', r.recordingStartedAt.add(Duration(seconds: i))),
              ]),
            );
            final db = await f.raw();
            try {
              await db.update(
                'route_points',
                invalid.value,
                where: 'sample_key = ?',
                whereArgs: [clipped ? 'p3' : 'p1'],
              );
              final before = await snapshot(db);
              await expectLater(
                f.controller.finishActivityRecording(
                  recordingId: r.recordingId,
                  endedAt: r.recordingStartedAt.add(const Duration(seconds: 2)),
                ),
                throwsA(integrityError),
              );
              expect(await snapshot(db), before);
            } finally {
              await db.close();
            }
          } finally {
            await f.delete();
          }
        },
      );
    }
  }

  for (final corruption in ['negative-edge', 'malformed-time']) {
    test(
      'resumed finalizing intent rejects $corruption without changing deadline',
      () async {
        var f = await RecordingFixture.create();
        try {
          final r = await seed(f, 4);
          f.store.failPhase = ActivityRecordingPhase.finished;
          await expectLater(
            f.controller.finishActivityRecording(recordingId: r.recordingId),
            throwsA(integrityError),
          );
          final db = await f.raw();
          Map<String, List<Map<String, Object?>>> before;
          try {
            expect(
              (await db.query('recordings')).single['phase'],
              'finalizing',
            );
            await db.update(
              'route_points',
              corruption == 'negative-edge'
                  ? {'edge_distance': -1}
                  : {'sampled_at': 'malformed'},
              where: 'sample_key = ?',
              whereArgs: [1.toRadixString(16).padLeft(64, '0')],
            );
            before = await snapshot(db);
          } finally {
            await db.close();
          }
          final directory = f.directory;
          final sessions = f.sessionStore;
          final now = f.now;
          await f.dispose();
          f = await RecordingFixture.create(
            directory: directory,
            sessionStore: sessions,
          );
          f.now = now;
          final reopened = await f.raw();
          try {
            for (var retry = 0; retry < 2; retry++) {
              await expectLater(
                f.controller.finishActivityRecording(
                  recordingId: r.recordingId,
                ),
                throwsA(integrityError),
              );
              expect(await snapshot(reopened), before);
            }
          } finally {
            await reopened.close();
          }
        } finally {
          await f.delete();
        }
      },
    );
  }

  for (final failBatch in [null, 2]) {
    test(
      'Finish validates all keyset batches before mutation; query failure=$failBatch',
      () async {
        final f = await RecordingFixture.create();
        try {
          final r = await seed(f, 1100);
          final db = await f.raw();
          try {
            final record = ActivityRecordingRecord.decode(
              (await db.query('recordings')).single,
            );
            final before = await snapshot(db);
            late ValidationSpy spy;
            final finish = db.transaction((tx) async {
              spy = ValidationSpy(tx, failBatch: failBatch);
              final result = await ActivityRecordingRouteSql(spy).finish(
                record,
                r.recordingStartedAt.add(const Duration(seconds: 1000)),
              );
              expect(spy.validationRows, 1100);
              expect(spy.validationQueries, 3);
              expect(spy.largestBatch, lessThanOrEqualTo(512));
              expect(spy.firstMutationAfterValidationRows, 1100);
              expect(result.value.pointCount, 501);
              throw StateError('after-validating-before-commit');
            });
            await expectLater(
              finish,
              throwsA(
                isA<StateError>().having(
                  (e) => e.message,
                  'injection',
                  failBatch == null
                      ? 'after-validating-before-commit'
                      : 'validation-query-failed',
                ),
              ),
            );
            expect(await snapshot(db), before);
            if (failBatch != null) {
              expect(spy.firstMutationAfterValidationRows, isNull);
            }
          } finally {
            await db.close();
          }
        } finally {
          await f.delete();
        }
      },
    );
  }

  test(
    'valid resumed finalizing validation performs no SQL mutation',
    () async {
      final f = await RecordingFixture.create();
      try {
        final r = await seed(f, 4);
        f.store.failPhase = ActivityRecordingPhase.finished;
        await expectLater(
          f.controller.finishActivityRecording(recordingId: r.recordingId),
          throwsA(integrityError),
        );
        final db = await f.raw();
        try {
          final before = await snapshot(db);
          final record = ActivityRecordingRecord.decode(
            before['recordings']!.single,
          );
          await db.transaction((tx) async {
            final spy = ValidationSpy(tx);
            final result = await ActivityRecordingRouteSql(
              spy,
            ).finish(record, record.value.endedAt!);
            expect(identical(result, record), isTrue);
            expect(spy.validationRows, 4);
            expect(
              spy.counts.keys.every((op) => op.startsWith('query:')),
              isTrue,
            );
            expect(spy.firstMutationAfterValidationRows, isNull);
          });
          expect(await snapshot(db), before);
        } finally {
          await db.close();
        }
      } finally {
        await f.delete();
      }
    },
  );

  test(
    'public Finish sanitizes a validation SELECT failure without watcher publication',
    () async {
      final factory = _ValidationFaultFactory();
      final f = await RecordingFixture.create(factory: factory);
      try {
        final r = await seed(f, 1100);
        final observed = <SdkActivityRecording?>[];
        final watch = f.controller.watchActiveActivityRecording().listen(
          observed.add,
        );
        try {
          await pumpEventQueue();
          final emissions = observed.length;
          final db = await f.raw();
          try {
            final before = await snapshot(db);
            factory.armed = true;
            for (var retry = 0; retry < 2; retry++) {
              await expectLater(
                f.controller.finishActivityRecording(
                  recordingId: r.recordingId,
                  endedAt: r.recordingStartedAt,
                ),
                throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
              );
              await pumpEventQueue();
              expect(factory.batches, 2);
              expect(await snapshot(db), before);
              expect(observed.length, emissions);
            }
            factory.armed = false;
            expect(
              (await f.controller.finishActivityRecording(
                recordingId: r.recordingId,
              )).phase,
              ActivityRecordingPhase.finished,
            );
          } finally {
            await db.close();
          }
        } finally {
          await watch.cancel();
        }
      } finally {
        await f.delete();
      }
    },
  );

  test(
    'corruption beyond two validation batches cannot be deleted by cutoff',
    () async {
      final f = await RecordingFixture.create();
      try {
        final r = await seed(f, 1100);
        final db = await f.raw();
        try {
          await db.update(
            'route_points',
            {'sampled_at': 'malformed'},
            where: 'sample_key = ?',
            whereArgs: [1099.toRadixString(16).padLeft(64, '0')],
          );
          final before = await snapshot(db);
          await expectLater(
            f.controller.finishActivityRecording(
              recordingId: r.recordingId,
              endedAt: r.recordingStartedAt,
            ),
            throwsA(integrityError),
          );
          expect(await snapshot(db), before);
        } finally {
          await db.close();
        }
      } finally {
        await f.delete();
      }
    },
  );

  for (final count in [0, 1, 4, 10000, 100000]) {
    test(
      'valid full validation and historical clipping $count points',
      () async {
        final f = await RecordingFixture.create();
        try {
          final r = await seed(f, count);
          final cutoff = count < 2
              ? f.now
              : r.lastSampleAt!.subtract(const Duration(seconds: 2));
          final db = await f.raw();
          double? expectedDistance;
          try {
            expectedDistance =
                (await db.rawQuery(
                      'SELECT SUM(edge_distance) AS d FROM route_points WHERE recording_id = ? AND sample_order <= ?',
                      [r.recordingId, cutoff.microsecondsSinceEpoch],
                    )).single['d']
                    as double?;
          } finally {
            await db.close();
          }
          // AR3 can end the logical session before finishing the recording by ID.
          await f.sessions.endActivitySession(sessionId: r.activitySessionId);
          final done = await f.controller.finishActivityRecording(
            recordingId: r.recordingId,
            endedAt: cutoff,
          );
          expect(done.phase, ActivityRecordingPhase.finished);
          expect(done.pointCount, count < 2 ? count : count - 1);
          expect(
            done.recordedDistanceMeters,
            expectedDistance == null ? isNull : closeTo(expectedDistance, 1e-7),
          );
          expect(
            (await f.controller.getActivityRecording(
              recordingId: r.recordingId,
            ))!.endedAt,
            cutoff,
          );
        } finally {
          await f.delete();
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  test(
    'corrupt active D leaves finished A/B/C immutable and owner-isolated',
    () async {
      final f = await RecordingFixture.create();
      try {
        final finished = <String>[];
        for (var i = 0; i < 3; i++) {
          final r = await seed(f, 4);
          await f.controller.finishActivityRecording(
            recordingId: r.recordingId,
          );
          await f.sessions.endActivitySession(sessionId: r.activitySessionId);
          finished.add(r.recordingId);
        }
        final r = await seed(f, 4);
        final db = await f.raw();
        try {
          await db.update(
            'route_points',
            {'edge_distance': -1},
            where: 'recording_id = ? AND sample_key = ?',
            whereArgs: [r.recordingId, 1.toRadixString(16).padLeft(64, '0')],
          );
          final before = await snapshot(db);
          await expectLater(
            f.controller.finishActivityRecording(recordingId: r.recordingId),
            throwsA(integrityError),
          );
          expect(await snapshot(db), before);
          for (final id in finished) {
            expect(
              (await f.controller.getActivityRecording(recordingId: id))!.phase,
              ActivityRecordingPhase.finished,
            );
            expect(
              (await f.controller.finishActivityRecording(
                recordingId: id,
              )).phase,
              ActivityRecordingPhase.finished,
            );
          }
          expect(await snapshot(db), before);
          await f.bind(recordingUserB);
          expect(
            await f.controller.getActivityRecording(recordingId: r.recordingId),
            isNull,
          );
          expect(await db.query('route_points'), isEmpty);
          expect(await db.query('recordings'), isEmpty);
        } finally {
          await db.close();
        }
      } finally {
        await f.delete();
      }
    },
  );
}

/// Observes only the dedicated full-point validation queries. No production seam.
class ValidationSpy extends Spy {
  ValidationSpy(super.inner, {this.failBatch});
  final int? failBatch;
  int validationQueries = 0;
  int validationRows = 0;
  int largestBatch = 0;
  int? firstMutationAfterValidationRows;

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
    final validation =
        table == 'route_points' && orderBy == 'sample_key' && columns == null;
    if (validation) {
      validationQueries++;
      expect(limit, 512);
      expect(offset, isNull);
      if (validationQueries > 1) expect(where, contains('sample_key > ?'));
      if (validationQueries == failBatch) {
        throw StateError('validation-query-failed');
      }
    }
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
    if (validation) {
      validationRows += rows.length;
      if (rows.length > largestBatch) largestBatch = rows.length;
    }
    return rows;
  }

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) {
    firstMutationAfterValidationRows ??= validationRows;
    return super.delete(table, where: where, whereArgs: whereArgs);
  }
}

class _ValidationFaultFactory implements DatabaseFactory {
  bool armed = false;
  int batches = 0;
  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async => _ValidationFaultDatabase(
    await databaseFactoryFfiNoIsolate.openDatabase(path, options: options),
    this,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ValidationFaultDatabase implements Database {
  _ValidationFaultDatabase(this.inner, this.fault);
  final Database inner;
  final _ValidationFaultFactory fault;
  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction) action, {
    bool? exclusive,
  }) => inner.transaction(
    (tx) => action(_ValidationFaultTransaction(tx, fault)),
    exclusive: exclusive,
  );
  @override
  Future<void> close() => inner.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ValidationFaultTransaction extends Spy implements Transaction {
  _ValidationFaultTransaction(super.inner, this.fault);
  final _ValidationFaultFactory fault;
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
  }) {
    if (fault.armed &&
        table == 'route_points' &&
        orderBy == 'sample_key' &&
        columns == null) {
      if (whereArgs!.length == 1) fault.batches = 0;
      if (++fault.batches == 2) {
        throw StateError('private validation query failure');
      }
    }
    return super.query(
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
  }
}
