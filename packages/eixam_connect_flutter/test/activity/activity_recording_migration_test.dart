import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_database.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_record.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'recording_test_support.dart';
import 'activity_recording_ingestion_test.dart' show batch, sample;

void main() {
  late RecordingFixture f;
  setUp(() async => f = await RecordingFixture.create());
  tearDown(() => f.delete());

  Future<String> seed(
    ActivityRecordingPhase phase, {
    bool unexpectedRoute = false,
  }) async {
    final r = await f.start(device: tagA);
    final owner = ActivityRecordingOwner.forIdentity(f.backend, recordingUserA);
    final path = '${f.directory.path}/legacy.sqlite';
    final db = await databaseFactoryFfiNoIsolate.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        singleInstance: false,
        onCreate: (db, _) async {
          for (final statement in (await File(
            'test/activity/fixtures/activity_recording_v1.sql',
          ).readAsString()).split(';')) {
            if (statement.trim().isNotEmpty) {
              await db.execute(statement);
            }
          }
        },
      ),
    );
    await db.insert('recording_store_metadata', {
      'singleton': 1,
      'owner_scope': owner.scope,
      'sdk_user_id': owner.sdkUserId,
      'canonical_user_id': owner.canonicalUserId,
    });
    final record = ActivityRecordingRecord(owner, r);
    for (var i = 0; i < 3; i++) {
      final values = {
        ...record.encode(),
        'recording_id': i.toRadixString(16).padLeft(32, '0'),
        'activity_session_id': 'session-$i',
        'phase': i == 0 ? phase.name : ActivityRecordingPhase.finished.name,
        'ended_at': i == 0 && phase == ActivityRecordingPhase.active
            ? null
            : f.now.toIso8601String(),
      };
      await db.insert('recordings', values);
    }
    if (unexpectedRoute) {
      await db.insert('route_points', {
        'recording_id': '00000000000000000000000000000000',
        'sample_key': 'unapproved-v1-point',
        'sampled_at': f.now.toIso8601String(),
        'latitude': 1.0,
        'longitude': 1.0,
        'delivery': 'live',
        'segment_id': 'legacy',
      });
    }
    await db.close();
    return path;
  }

  for (final phase in ActivityRecordingPhase.values) {
    test(
      'schema1→4 preserves $phase plus all finished metadata and binding',
      () async {
        final path = await seed(phase);
        final db = ActivityRecordingDatabase(
          path: path,
          factory: databaseFactoryFfiNoIsolate,
        );
        try {
          final owner = ActivityRecordingOwner.forIdentity(
            f.backend,
            recordingUserA,
          );
          for (var i = 0; i < 3; i++) {
            final r = await db.transaction(
              (tx) =>
                  tx.byId(owner.scope, i.toRadixString(16).padLeft(32, '0')),
            );
            expect(
              r!.value.phase,
              i == 0 ? phase : ActivityRecordingPhase.finished,
            );
            expect(r.value.deviceIdentity, tagA);
            expect(r.value.pointCount, 0);
            expect(r.value.routeRevision, 0);
          }
        } finally {
          await db.dispose();
        }
        final raw = await databaseFactoryFfiNoIsolate.openDatabase(
          path,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        expect(await raw.getVersion(), 4);
        expect((await raw.query('recordings')).length, 3);
        expect(
          (await raw.query(
            'recording_store_metadata',
          )).single['canonical_user_id'],
          'a',
        );
        await raw.close();
      },
    );
  }

  for (final oldVersion in [2, 3]) {
    test(
      'schema$oldVersion→4 preserves active integrity gap and multiple finished routes byte-for-byte',
      () async {
        final ids = <String>[];
        for (var i = 0; i < 3; i++) {
          final r = await f.start(device: tagA);
          ids.add(r.recordingId);
          f.now = f.now.add(const Duration(seconds: 10));
          await f.controller.ingestLive(
            batch(f, [
              sample('a', r.recordingStartedAt),
              sample(
                'b',
                r.recordingStartedAt.add(const Duration(seconds: 1)),
                longitude: 2,
              ),
            ]),
          );
          if (i == 2) {
            await f.controller.ingestLive(
              batch(f, [sample('a', r.recordingStartedAt, longitude: 5)]),
            );
          } else {
            await f.controller.finishActivityRecording(
              recordingId: r.recordingId,
            );
            await f.sessions.endActivitySession(sessionId: r.activitySessionId);
          }
        }
        final source = await f.raw();
        if (oldVersion == 3) {
          final first = (await source.query(
            'recordings',
            where: 'recording_id = ?',
            whereArgs: [ids.first],
          )).single;
          await source.update(
            'recording_recovery',
            {
              'processed_through': DateTime.parse(
                first['last_sample_at'] as String,
              ).microsecondsSinceEpoch,
            },
            where: 'recording_id = ?',
            whereArgs: [ids.first],
          );
        }
        final snapshot = <String, List<Map<String, Object?>>>{};
        for (final table in [
          'recording_store_metadata',
          'recordings',
          'route_points',
          'route_gaps',
          if (oldVersion == 3) 'recording_recovery',
        ]) {
          snapshot[table] = (await source.query(table))
              .map(
                (row) => Map<String, Object?>.of(row)
                  ..remove('finalization_started_at')
                  ..remove('finalization_deadline_at'),
              )
              .toList();
        }
        await source.close();
        final path = '${f.directory.path}/v$oldVersion.sqlite';
        final legacy = await databaseFactoryFfiNoIsolate.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: oldVersion,
            singleInstance: false,
            onCreate: (db, _) async {
              for (final statement in (await File(
                'test/activity/fixtures/activity_recording_v$oldVersion.sql',
              ).readAsString()).split(';')) {
                if (statement.trim().isNotEmpty) await db.execute(statement);
              }
            },
          ),
        );
        for (final entry in snapshot.entries) {
          for (final row in entry.value) {
            await legacy.insert(entry.key, row);
          }
        }
        await legacy.close();
        final migrated = ActivityRecordingDatabase(
          path: path,
          factory: databaseFactoryFfiNoIsolate,
        );
        final owner = ActivityRecordingOwner.forIdentity(
          f.backend,
          recordingUserA,
        );
        for (final id in ids) {
          final record = await migrated.transaction(
            (tx) => tx.byId(owner.scope, id),
          );
          expect(record!.value.pointCount, 2);
          expect(record.value.deviceIdentity, tagA);
        }
        await migrated.dispose();
        final raw = await databaseFactoryFfiNoIsolate.openDatabase(
          path,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        expect(await raw.getVersion(), 4);
        for (final entry in snapshot.entries) {
          expect(
            (await raw.query(entry.key))
                .map(
                  (row) => Map<String, Object?>.of(row)
                    ..remove('finalization_started_at')
                    ..remove('finalization_deadline_at'),
                )
                .toList(),
            entry.value,
          );
        }
        final recovery = await raw.query(
          'recording_recovery',
          where: 'recording_id = ?',
          whereArgs: [ids.last],
        );
        if (oldVersion == 2) {
          expect(recovery.single['needed'], 1);
        } else {
          expect(
            recovery,
            isEmpty,
          ); // V3 may infer need from gaps without a cursor row.
        }
        await raw.close();
      },
    );
  }

  test(
    'unexpected v1 route evidence aborts migration and preserves original schema/data',
    () async {
      final path = await seed(
        ActivityRecordingPhase.active,
        unexpectedRoute: true,
      );
      final db = ActivityRecordingDatabase(
        path: path,
        factory: databaseFactoryFfiNoIsolate,
      );
      await expectLater(
        db.transaction((tx) => tx.active('unknown')),
        throwsA(recordingError('E_RECORDING_RESTORE_FAILED')),
      );
      await db.dispose();
      final raw = await databaseFactoryFfiNoIsolate.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      expect(await raw.getVersion(), 1);
      expect(
        (await raw.query('route_points')).single['sample_key'],
        'unapproved-v1-point',
      );
      expect((await raw.query('recordings')).length, 3);
      await raw.close();
    },
  );
}
