import 'package:flutter_test/flutter_test.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'activity_recording_history_test_support.dart';
import 'recording_test_support.dart';

void main() {
  late RecordingFixture f;
  setUp(() async => f = await RecordingFixture.create());
  tearDown(() => f.delete());

  final corruptions = <String, Object?>{
    'phase': 'unknown',
    'ended_at': null,
    'recording_id': 'invalid',
    'owner_scope': 'invalid-owner',
    'activity_key': 'BAD KEY',
    'input_state': 'unknown',
    'recovery_state': 'unknown',
    'route_quality': 'complete',
    'point_count': -1,
    'segment_count': -1,
    'unresolved_gap_count': -1,
    'distance_meters': -1.0,
    'issues': '["unknown"]',
    'route_revision': 2,
    'previous_route_revision': 1,
    'session_started_at': 'not-a-timestamp',
    'recording_started_at': '2026-10-20T00:00:00+00:00',
    'device_identity': 'not-a-device',
  };
  for (final corruption in corruptions.entries) {
    for (final prepared in [false, true]) {
      test(
        '${prepared ? 'warm' : 'cold'} malformed ${corruption.key} fails whole page and preserves evidence',
        () async {
          await seedHistory(f, [historyRecord(f, 1), historyRecord(f, 2)]);
          if (prepared) await f.controller.listFinishedActivityRecordings();
          final raw = await f.raw();
          await raw.execute('PRAGMA ignore_check_constraints = ON');
          await raw.execute('PRAGMA foreign_keys = OFF');
          await raw.update(
            'recordings',
            {corruption.key: corruption.value},
            where: 'recording_id = ?',
            whereArgs: [historyId(1)],
          );
          final before = await raw.query('recordings');
          await expectLater(
            f.controller.listFinishedActivityRecordings(limit: 1),
            throwsA(recordingError('E_RECORDING_RESTORE_FAILED')),
          );
          expect(await raw.query('recordings'), before);
          await raw.close();
        },
      );
    }
  }

  for (final corruption in [
    'missing',
    'orphan',
    'wrong-time',
    'wrong-owner',
    'bad-time-type',
    'nonfinished',
  ]) {
    test(
      '$corruption ordering entry fails closed without rebuilding',
      () async {
        await seedHistory(f, [historyRecord(f, 1)]);
        final raw = await f.raw();
        await raw.execute('PRAGMA foreign_keys = OFF');
        switch (corruption) {
          case 'missing':
            await raw.delete('recording_history_order');
          case 'orphan':
            await raw.insert('recording_history_order', {
              'recording_id': historyId(99),
              'owner_scope': historyRecord(f, 1).owner.scope,
              'ended_at_us': f.now.microsecondsSinceEpoch,
            });
          case 'wrong-time':
            await raw.update('recording_history_order', {'ended_at_us': 0});
          case 'wrong-owner':
            await raw.update('recording_history_order', {
              'owner_scope': 'foreign',
            });
          case 'bad-time-type':
            await raw.update('recording_history_order', {'ended_at_us': 'bad'});
          case 'nonfinished':
            await raw.update('recordings', {'phase': 'finalizing'});
        }
        final before = await raw.query('recording_history_order');
        await expectLater(
          f.controller.listFinishedActivityRecordings(),
          throwsA(recordingError('E_RECORDING_RESTORE_FAILED')),
        );
        expect(await raw.query('recording_history_order'), before);
        await raw.close();
      },
    );
  }

  test(
    'finished writes refuse to silently repair missing or mismatched ordering',
    () async {
      final record = historyRecord(f, 1);
      await seedHistory(f, [record]);
      final raw = await f.raw();
      await raw.delete('recording_history_order');
      await expectLater(
        f.database.transaction((tx) => tx.update(record)),
        throwsA(recordingError('E_RECORDING_RESTORE_FAILED')),
      );
      expect(await raw.query('recording_history_order'), isEmpty);
      await raw.close();
    },
  );

  test(
    'ordering insert failure rolls back the durable finished summary',
    () async {
      final recording = await f.start();
      final raw = await f.raw();
      await raw.execute('''CREATE TRIGGER fail_history_insert BEFORE INSERT
      ON recording_history_order BEGIN SELECT RAISE(ABORT, 'injected'); END''');
      await expectLater(
        f.controller.finishActivityRecording(
          recordingId: recording.recordingId,
        ),
        throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
      );
      expect((await raw.query('recordings')).single['phase'], 'finalizing');
      expect(await raw.query('recording_history_order'), isEmpty);
      await raw.execute('DROP TRIGGER fail_history_insert');
      await f.controller.finishActivityRecording(
        recordingId: recording.recordingId,
      );
      expect(
        (await f.controller.listFinishedActivityRecordings()).items,
        hasLength(1),
      );
      await raw.close();
    },
  );

  test('finish cannot silently adopt a premature ordering entry', () async {
    final pending = historyRecord(
      f,
      1,
      phase: ActivityRecordingPhase.finalizing,
    );
    await seedHistory(f, [pending]);
    final raw = await f.raw();
    await raw.insert('recording_history_order', {
      'recording_id': pending.value.recordingId,
      'owner_scope': pending.owner.scope,
      'ended_at_us': pending.value.endedAt!.microsecondsSinceEpoch,
    });
    await expectLater(
      f.database.transaction((tx) => tx.update(historyRecord(f, 1))),
      throwsA(recordingError('E_RECORDING_RESTORE_FAILED')),
    );
    expect((await raw.query('recordings')).single['phase'], 'finalizing');
    expect(await raw.query('recording_history_order'), hasLength(1));
    await raw.close();
  });
}
