import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'activity_recording_history_test_support.dart';
import 'activity_recording_ingestion_test.dart' show batch, sample;
import 'recording_test_support.dart';

void main() {
  late RecordingFixture f;
  setUp(() async => f = await RecordingFixture.create());
  tearDown(() => f.delete());
  const tables = [
    'recordings',
    'route_points',
    'route_gaps',
    'recording_recovery',
    'recording_store_metadata',
  ];

  Future<void> makeLegacy(int version) async {
    await f.dispose();
    final raw = await f.raw();
    if (version == 4) {
      await raw.execute('DROP TABLE recording_history_order');
      await raw.execute('DROP INDEX recording_history_eligibility');
    }
    await raw.execute('ALTER TABLE recordings DROP COLUMN is_deleted');
    await raw.setVersion(version);
    await raw.close();
  }

  Future<void> reopen() async {
    f = await RecordingFixture.create(
      directory: f.directory,
      sessionStore: f.sessionStore,
    );
  }

  test(
    'fresh version 6 schema contains only ordering facts and required indexes',
    () async {
      await seedHistory(f, []);
      final raw = await f.raw();
      expect(await raw.getVersion(), 6);
      final columns = await raw.rawQuery(
        'PRAGMA table_info(recording_history_order)',
      );
      expect(columns.map((c) => c['name']), [
        'recording_id',
        'owner_scope',
        'ended_at_us',
      ]);
      final indexes = await raw.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index'",
      );
      expect(
        indexes.map((i) => i['name']),
        containsAll([
          'recording_history_page',
          'recording_history_eligibility',
        ]),
      );
      await raw.close();
    },
  );

  for (final oldVersion in [4, 5]) {
    for (final phase in [
      ActivityRecordingPhase.active,
      ActivityRecordingPhase.finalizing,
    ]) {
      test(
        'v$oldVersion to v6 preserves all existing rows with $phase and finished routes',
        () async {
          final finished = await f.start(device: tagA);
          f.now = f.now.add(const Duration(seconds: 5));
          await f.controller.ingestLive(
            batch(f, [
              sample('a', finished.recordingStartedAt),
              sample(
                'b',
                finished.recordingStartedAt.add(const Duration(seconds: 1)),
              ),
            ]),
          );
          await f.controller.inputDisconnected(tagA, false);
          await f.controller.finishActivityRecording(
            recordingId: finished.recordingId,
          );
          await f.sessions.endActivitySession(
            sessionId: finished.activitySessionId,
          );
          final active = await f.start(device: tagA);
          if (phase == ActivityRecordingPhase.finalizing) {
            final raw = await f.raw();
            await raw.update(
              'recordings',
              {'phase': 'finalizing', 'ended_at': f.now.toIso8601String()},
              where: 'recording_id = ?',
              whereArgs: [active.recordingId],
            );
            await raw.close();
          }
          await makeLegacy(oldVersion);
          final before = await f.raw();
          final snapshot = <String, List<Map<String, Object?>>>{};
          final preservedTables = [
            ...tables,
            if (oldVersion == 5) 'recording_history_order',
          ];
          for (final table in preservedTables) {
            snapshot[table] = await before.query(table);
          }
          await before.close();
          await reopen();
          final result = await f.controller.listFinishedActivityRecordings();
          expect(result.items.single.recordingId, finished.recordingId);
          final after = await f.raw();
          expect(await after.getVersion(), 6);
          for (final table in preservedTables) {
            final rows = await after.query(table);
            if (table == 'recordings') {
              expect(rows.every((r) => r['is_deleted'] == 0), isTrue);
            }
            expect(
              rows
                  .map((r) => Map<String, Object?>.of(r)..remove('is_deleted'))
                  .toList(),
              snapshot[table],
              reason: table,
            );
          }
          expect(
            (await after.query(
              'recording_history_order',
            )).single['ended_at_us'],
            DateTime.parse(
              snapshot['recordings']!.firstWhere(
                    (r) => r['recording_id'] == finished.recordingId,
                  )['ended_at']
                  as String,
            ).microsecondsSinceEpoch,
          );
          await after.close();
          await f.dispose();
          await reopen();
          expect(
            (await f.controller.listFinishedActivityRecordings())
                .items
                .single
                .recordingId,
            finished.recordingId,
          );
        },
      );
    }
  }

  for (final field in ['ended_at', 'issues', 'phase']) {
    test(
      'malformed v4 $field rolls back migration and preserves v4 evidence',
      () async {
        await seedHistory(f, [historyRecord(f, 1)]);
        await makeLegacy(4);
        final raw = await f.raw();
        await raw.execute('PRAGMA ignore_check_constraints = ON');
        await raw.update('recordings', {
          field: field == 'ended_at' ? null : 'invalid',
        });
        final before = await raw.query('recordings');
        await raw.close();
        await reopen();
        await expectLater(
          f.controller.listFinishedActivityRecordings(),
          throwsA(recordingError('E_RECORDING_RESTORE_FAILED')),
        );
        final evidence = await f.raw();
        expect(await evidence.getVersion(), 4);
        expect(await evidence.query('recordings'), before);
        expect(
          await evidence.rawQuery(
            "SELECT 1 FROM sqlite_master WHERE name='recording_history_order'",
          ),
          isEmpty,
        );
        await evidence.close();
      },
    );
  }

  test(
    'v4 backfill spans bounded batches and preserves microsecond ordering',
    () async {
      final base = f.now;
      await seedHistory(
        f,
        List.generate(
          700,
          (i) => historyRecord(f, i, end: base.add(Duration(microseconds: i))),
        ),
      );
      await makeLegacy(4);
      final before = await f.raw();
      final summaries = await before.query('recordings');
      await before.close();
      await reopen();
      final page = await f.controller.listFinishedActivityRecordings(
        limit: 100,
      );
      expect(
        page.items.map((r) => r.recordingId),
        List.generate(100, (i) => historyId(699 - i)),
      );
      final raw = await f.raw();
      final rows = await raw.query('recordings');
      expect(rows.every((r) => r['is_deleted'] == 0), isTrue);
      expect(
        rows
            .map((r) => Map<String, Object?>.of(r)..remove('is_deleted'))
            .toList(),
        summaries,
      );
      expect(await raw.query('recording_history_order'), hasLength(700));
      await raw.close();
    },
  );
}
