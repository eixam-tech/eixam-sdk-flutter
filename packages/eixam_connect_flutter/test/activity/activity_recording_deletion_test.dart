import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'activity_recording_history_test_support.dart';
import 'activity_recording_ingestion_test.dart' show batch, sample;
import 'recording_test_support.dart';

void main() {
  late RecordingFixture f;
  setUp(() async => f = await RecordingFixture.create());
  tearDown(() => f.delete());

  Future<SdkActivityRecording> finishRoute() async {
    final r = await f.start(device: tagA);
    f.now = f.now.add(const Duration(seconds: 10));
    await f.controller.ingestLive(
      batch(f, [
        sample('a', r.recordingStartedAt),
        sample('b', r.recordingStartedAt.add(const Duration(seconds: 1))),
        sample('c', r.recordingStartedAt.add(const Duration(seconds: 2))),
      ]),
    );
    await f.controller.inputDisconnected(tagA, false);
    return f.controller.finishActivityRecording(recordingId: r.recordingId);
  }

  test('soft delete changes only the flag and hides public reads', () async {
    final r = await finishRoute();
    await seedHistory(f, [historyRecord(f, 1)]);
    await f.controller.listFinishedActivityRecordings();
    final raw = await f.raw();
    final before = (await raw.query(
      'recordings',
      where: 'recording_id = ?',
      whereArgs: [r.recordingId],
    )).single;
    final retained = <String, List<Map<String, Object?>>>{};
    for (final table in [
      'route_points',
      'route_gaps',
      'recording_recovery',
      'recording_history_order',
      'recording_store_metadata',
    ]) {
      retained[table] = await raw.query(table);
    }
    expect(retained['route_points'], hasLength(3));
    expect(retained['route_gaps'], isNotEmpty);
    expect(retained['recording_recovery'], isNotEmpty);
    final control = f.controller as ActivityRecordingDeleteControl;
    await control.deleteFinishedActivityRecording(recordingId: r.recordingId);
    expect(
      (await raw.query(
        'recordings',
        where: 'recording_id = ?',
        whereArgs: [r.recordingId],
      )).single,
      {...before, 'is_deleted': 1},
    );
    for (final entry in retained.entries) {
      expect(await raw.query(entry.key), entry.value, reason: entry.key);
    }
    expect(await raw.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    await raw.close();
    expect(
      await f.controller.getActivityRecording(recordingId: r.recordingId),
      isNull,
    );
    await expectLater(
      f.controller
          .readActivityRecordingRoute(recordingId: r.recordingId)
          .toList(),
      throwsA(recordingError('E_RECORDING_NOT_FOUND')),
    );
    for (final operation in [
      () => f.controller.finishActivityRecording(recordingId: r.recordingId),
      () => f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      ),
    ]) {
      await expectLater(
        operation(),
        throwsA(recordingError('E_RECORDING_NOT_FOUND')),
      );
    }
    expect(
      (await f.controller.listFinishedActivityRecordings()).items.map(
        (r) => r.recordingId,
      ),
      [historyId(1)],
    );
    expect(
      await f.controller.getActivityRecording(recordingId: historyId(1)),
      isNotNull,
    );
    expect(
      (await f.sessions.getActiveActivitySession())?.sessionId,
      r.activitySessionId,
    );
    await expectLater(
      f.controller.startActivityRecording(
        activitySession: (await f.sessions.getActiveActivitySession())!,
      ),
      throwsA(recordingError('E_RECORDING_ALREADY_FINISHED')),
    );
    final writes = f.store.committedWrites;
    await control.deleteFinishedActivityRecording(recordingId: r.recordingId);
    expect(f.store.committedWrites, writes);
  });

  test(
    'pagination filters before limit and preserves deleted cursor boundaries',
    () async {
      await seedHistory(f, List.generate(8, (i) => historyRecord(f, i)));
      final first = await f.controller.listFinishedActivityRecordings(limit: 2);
      expect(first.items.map((r) => r.recordingId), [
        historyId(7),
        historyId(6),
      ]);
      for (final id in [7, 6, 5, 4, 2]) {
        await f.controller.deleteFinishedActivityRecording(
          recordingId: historyId(id),
        );
      }
      final next = await f.controller.listFinishedActivityRecordings(
        limit: 2,
        cursor: first.nextCursor,
      );
      expect(next.items.map((r) => r.recordingId), [
        historyId(3),
        historyId(1),
      ]);
      expect(
        (await f.controller.listFinishedActivityRecordings(
          limit: 2,
          cursor: next.nextCursor,
        )).items.single.recordingId,
        historyId(0),
      );
      expect(
        (await f.controller.listFinishedActivityRecordings()).items.map(
          (r) => r.recordingId,
        ),
        [historyId(3), historyId(1), historyId(0)],
      );
    },
  );

  test('restart preserves hiding, route absence and idempotency', () async {
    final r = await finishRoute();
    await f.controller.deleteFinishedActivityRecording(
      recordingId: r.recordingId,
    );
    await f.dispose();
    f = await RecordingFixture.create(
      directory: f.directory,
      sessionStore: f.sessionStore,
    );
    expect(
      (await f.controller.listFinishedActivityRecordings()).items,
      isEmpty,
    );
    expect(
      await f.controller.getActivityRecording(recordingId: r.recordingId),
      isNull,
    );
    await expectLater(
      f.controller
          .readActivityRecordingRoute(recordingId: r.recordingId)
          .toList(),
      throwsA(recordingError('E_RECORDING_NOT_FOUND')),
    );
    await f.controller.deleteFinishedActivityRecording(
      recordingId: r.recordingId,
    );
    final raw = await f.raw();
    expect((await raw.query('recordings')).single['is_deleted'], 1);
    expect(await raw.query('route_points'), hasLength(3));
    await raw.close();
  });

  for (final phase in [
    ActivityRecordingPhase.active,
    ActivityRecordingPhase.finalizing,
  ]) {
    test('$phase fails closed without restoring/finalizing it', () async {
      await seedHistory(f, [historyRecord(f, 1, phase: phase)]);
      await expectLater(
        f.controller.deleteFinishedActivityRecording(recordingId: historyId(1)),
        throwsA(recordingError('E_RECORDING_CONFLICT')),
      );
      final raw = await f.raw();
      final row = (await raw.query('recordings')).single;
      expect(row['phase'], phase.name);
      expect(row['is_deleted'], 0);
      await raw.close();
      expect(f.verifyCalls, 0);
      expect(f.store.committedWrites, 0);
    });
  }

  test('absent and foreign IDs are indistinguishable', () async {
    await seedHistory(f, [historyRecord(f, 1)]);
    await expectLater(
      f.controller.deleteFinishedActivityRecording(recordingId: historyId(99)),
      throwsA(recordingError('E_RECORDING_NOT_FOUND')),
    );
    await f.bind(recordingUserB);
    await seedHistory(f, [historyRecord(f, 2)]);
    await expectLater(
      f.controller.deleteFinishedActivityRecording(recordingId: historyId(1)),
      throwsA(recordingError('E_RECORDING_NOT_FOUND')),
    );
    expect(
      (await f.controller.listFinishedActivityRecordings())
          .items
          .single
          .recordingId,
      historyId(2),
    );
  });

  test('failed storage transaction rolls back deletion', () async {
    await seedHistory(f, [historyRecord(f, 1)]);
    f.store.failNextWrite = true;
    await expectLater(
      f.controller.deleteFinishedActivityRecording(recordingId: historyId(1)),
      throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
    );
    expect(
      await f.controller.getActivityRecording(recordingId: historyId(1)),
      isNotNull,
    );
    expect(
      (await f.controller.listFinishedActivityRecordings()).items,
      hasLength(1),
    );
    await f.controller.deleteFinishedActivityRecording(
      recordingId: historyId(1),
    );
  });

  test('paused route read cannot fetch another page after deletion', () async {
    final r = await finishRoute();
    final pages = StreamIterator(
      f.controller.readActivityRecordingRoute(
        recordingId: r.recordingId,
        pageSize: 1,
      ),
    );
    try {
      expect(await pages.moveNext(), isTrue);
      expect(pages.current.isLast, isFalse);
      await f.controller.deleteFinishedActivityRecording(
        recordingId: r.recordingId,
      );
      await expectLater(
        pages.moveNext(),
        throwsA(recordingError('E_RECORDING_NOT_FOUND')),
      );
    } finally {
      await pages.cancel();
    }
  });

  for (final cleanup in ['local', 'logout', 'owner']) {
    test(
      '$cleanup cleanup removes deleted rows and retained payload',
      () async {
        final r = await finishRoute();
        await f.controller.deleteFinishedActivityRecording(
          recordingId: r.recordingId,
        );
        await f.bind(
          cleanup == 'logout'
              ? null
              : cleanup == 'owner'
              ? recordingUserB
              : recordingUserA,
          clear: cleanup == 'local',
        );
        final raw = await f.raw();
        for (final table in [
          'recordings',
          'route_points',
          'route_gaps',
          'recording_recovery',
          'recording_history_order',
        ]) {
          expect(await raw.query(table), isEmpty, reason: table);
        }
        expect(await raw.rawQuery('PRAGMA foreign_key_check'), isEmpty);
        await raw.close();
      },
    );
  }
}
