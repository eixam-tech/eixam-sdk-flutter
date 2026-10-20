import 'dart:async';
import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_history_sql.dart';
import 'package:flutter_test/flutter_test.dart';

import 'activity_recording_history_test_support.dart';
import 'activity_recording_ingestion_test.dart' show batch, sample;
import 'recording_test_support.dart';

void main() {
  late RecordingFixture f;
  setUp(() async => f = await RecordingFixture.create());
  tearDown(() => f.delete());

  Future<void> reopen() async {
    final dir = f.directory;
    final sessions = f.sessionStore;
    await f.dispose();
    f = await RecordingFixture.create(
      directory: dir,
      sessionStore: sessions,
      user: f.user,
    );
  }

  Future<SdkActivityRecordingHistoryPage> page({
    int limit = 20,
    String? cursor,
  }) =>
      f.controller.listFinishedActivityRecordings(limit: limit, cursor: cursor);

  test('empty/default and bounded limits', () async {
    expect((await page()).items, isEmpty);
    expect((await page()).nextCursor, isNull);
    for (final limit in [-1, 0, 101, 1000000]) {
      await expectLater(page(limit: limit), throwsRangeError);
    }
    await seedHistory(f, List.generate(22, (i) => historyRecord(f, i)));
    expect((await page()).items, hasLength(20));
    expect((await page(limit: 100)).items, hasLength(22));
  });

  test('newest cutoff then descending ID; mixed timestamp precision', () async {
    final base = f.now;
    await seedHistory(f, [
      historyRecord(f, 1, end: base),
      historyRecord(f, 2, end: base.add(const Duration(microseconds: 1))),
      historyRecord(f, 3, end: base.add(const Duration(hours: 1))),
      historyRecord(f, 4, end: base.add(const Duration(hours: 1))),
    ]);
    expect(
      (await page()).items.map((r) => r.recordingId),
      [4, 3, 2, 1].map(historyId),
    );
  });

  test(
    'all pages and large timestamp ties have no duplicate or skipped IDs',
    () async {
      await seedHistory(
        f,
        List.generate(
          307,
          (i) => historyRecord(
            f,
            i,
            end: f.now.add(Duration(microseconds: i ~/ 150)),
          ),
        ),
      );
      final seen = <String>[];
      String? cursor;
      do {
        final result = await page(limit: 17, cursor: cursor);
        if (cursor != null) {
          final repeated = await page(limit: 17, cursor: cursor);
          expect(repeated.nextCursor, result.nextCursor);
          expect(
            repeated.items.map((r) => r.recordingId),
            result.items.map((r) => r.recordingId),
          );
        }
        seen.addAll(result.items.map((r) => r.recordingId));
        cursor = result.nextCursor;
      } while (cursor != null);
      expect(seen, List.generate(307, (i) => historyId(306 - i)));
      expect(seen.toSet(), hasLength(307));
    },
  );

  test(
    'new head does not shift continuation; delayed older finish may appear',
    () async {
      await seedHistory(f, [
        for (var i = 0; i < 6; i++)
          historyRecord(f, i, end: f.now.add(Duration(seconds: i * 2))),
      ]);
      final first = await page(limit: 2);
      await seedHistory(f, [
        historyRecord(f, 99, end: f.now.add(const Duration(hours: 1))),
        historyRecord(f, 98, end: f.now.add(const Duration(seconds: 5))),
      ]);
      final second = await page(limit: 100, cursor: first.nextCursor);
      expect(
        second.items.map((r) => r.recordingId),
        [3, 98, 2, 1, 0].map(historyId),
      );
      expect((await page()).items.first.recordingId, historyId(99));
    },
  );

  test(
    'finished partial, unknown and null distance preserve metadata exactly',
    () async {
      await seedHistory(f, [
        historyRecord(f, 1, partial: true),
        historyRecord(f, 2),
        historyRecord(f, 3, phase: ActivityRecordingPhase.active),
      ]);
      final result = await page();
      expect(result.items.map((r) => r.recordingId), [2, 1].map(historyId));
      expect(
        result.items.every((r) => r.recordedDistanceMeters == null),
        isTrue,
      );
      expect(
        result.items.first.routeQuality,
        ActivityRecordingRouteQuality.unknown,
      );
      expect(
        result.items.last.routeQuality,
        ActivityRecordingRouteQuality.partial,
      );
      expect(result.items.last.unresolvedGapCount, 1);
      expect(result.items.last.issues, {ActivityRecordingIssue.recoveryFailed});
    },
  );

  for (final phase in [
    ActivityRecordingPhase.active,
    ActivityRecordingPhase.finalizing,
  ]) {
    test(
      'cold $phase listing never accesses routes or restores lifecycle',
      () async {
        await seedHistory(f, [
          historyRecord(f, 1),
          historyRecord(f, 2, phase: phase),
        ]);
        await reopen();
        final raw = await f.raw();
        final before = await raw.query('recordings');
        for (final table in [
          'recording_recovery',
          'route_points',
          'route_gaps',
        ]) {
          await raw.execute('DROP TABLE $table');
        }
        expect((await page()).items.single.recordingId, historyId(1));
        await pumpEventQueue();
        expect(await raw.query('recordings'), before);
        expect(f.verifyCalls, 0);
        // Exercise and inspect the real focused SQL boundary too.
        await raw.transaction((tx) async {
          final trace = HistoryQueryTrace(tx);
          final sql = ActivityRecordingHistorySql(trace);
          final scope = historyRecord(f, 1).owner.scope;
          await sql.prepare(scope);
          expect(await sql.page(scope, limit: 2), hasLength(1));
          expect(trace.queries, isNotEmpty);
        });
        await raw.close();
      },
    );
  }

  test(
    'metadata preparation is cached; normal finish adds an atomic entry',
    () async {
      final r = await f.start();
      expect((await page()).items, isEmpty);
      final finished = await f.controller.finishActivityRecording(
        recordingId: r.recordingId,
      );
      expect((await page()).items.single.recordingId, finished.recordingId);
      expect(f.store.historyPrepareCalls, 1);
      final raw = await f.raw();
      final order = (await raw.query('recording_history_order')).single;
      expect(order['ended_at_us'], finished.endedAt!.microsecondsSinceEpoch);
      await raw.close();
    },
  );

  test(
    'history preparation leaves subsequent active restoration available',
    () async {
      f.connected = true;
      final active = await f.start(device: tagA);
      // Connected binding alone is deliberately unavailable until genuine TAG
      // input establishes observation. Persist that state before cold restart.
      await f.controller.ingestLive(batch(f, [sample('live', f.now)]));
      await seedHistory(f, [historyRecord(f, 1)]);
      await reopen();
      expect((await page()).items.single.recordingId, historyId(1));
      final raw = await f.raw();
      expect(
        (await raw.query(
          'recordings',
          where: 'recording_id = ?',
          whereArgs: [active.recordingId],
        )).single['input_state'],
        'observing',
      );
      expect(
        (await f.controller.getActiveActivityRecording())!.inputState,
        ActivityRecordingInputState.disconnected,
      );
      await raw.close();
    },
  );

  for (final loseAck in [false, true]) {
    test(
      'finish ${loseAck ? 'lost ACK' : 'rollback'} keeps summary/order atomic',
      () async {
        final r = await f.start();
        if (loseAck) {
          f.store.loseAcknowledgementPhase = ActivityRecordingPhase.finished;
          await f.controller.finishActivityRecording(
            recordingId: r.recordingId,
          );
        } else {
          f.store.failPhase = ActivityRecordingPhase.finished;
          await expectLater(
            f.controller.finishActivityRecording(recordingId: r.recordingId),
            throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
          );
        }
        final raw = await f.raw();
        final summary = (await raw.query('recordings')).single;
        expect(
          await raw.query('recording_history_order'),
          loseAck ? hasLength(1) : isEmpty,
        );
        expect(summary['phase'], loseAck ? 'finished' : 'finalizing');
        await raw.close();
        if (!loseAck) {
          f.store.failPhase = null;
          await f.controller.finishActivityRecording(
            recordingId: r.recordingId,
          );
        }
        expect((await page()).items.single.recordingId, r.recordingId);
      },
    );
  }

  test(
    'listed recording still supports authoritative known-ID and route reads',
    () async {
      final r = await f.start(device: tagA);
      f.now = f.now.add(const Duration(seconds: 2));
      await f.controller.ingestLive(
        batch(f, [
          sample('a', r.recordingStartedAt),
          sample('b', r.recordingStartedAt.add(const Duration(seconds: 1))),
        ]),
      );
      await f.controller.finishActivityRecording(recordingId: r.recordingId);
      final item = (await page()).items.single;
      final detail = (await f.controller.getActivityRecording(
        recordingId: item.recordingId,
      ))!;
      expect(detail.recordedDistanceMeters, item.recordedDistanceMeters);
      expect(detail.pointCount, item.pointCount);
      final routes = await f.controller
          .readActivityRecordingRoute(recordingId: item.recordingId)
          .toList();
      expect(
        routes.expand((p) => p.segments).expand((s) => s.points),
        hasLength(2),
      );
    },
  );

  test('cursor survives restart and same-principal signing rotation', () async {
    await seedHistory(f, [historyRecord(f, 1), historyRecord(f, 2)]);
    final first = await page(limit: 1);
    await reopen();
    await f.bind(recordingUserA.copyWith(userHash: 'rotated'));
    expect(
      (await page(cursor: first.nextCursor)).items.single.recordingId,
      historyId(1),
    );
  });

  test(
    'foreign owner cursor fails and logout clears ordering storage',
    () async {
      await seedHistory(f, [historyRecord(f, 1), historyRecord(f, 2)]);
      final cursor = (await page(limit: 1)).nextCursor;
      await f.bind(recordingUserB);
      await seedHistory(f, [historyRecord(f, 3)]);
      await expectLater(
        page(cursor: cursor),
        throwsA(recordingError('E_RECORDING_INVALID_CURSOR')),
      );
      expect((await page()).items.single.recordingId, historyId(3));
      await f.bind(null, clear: true);
      final raw = await f.raw();
      expect(await raw.query('recording_history_order'), isEmpty);
      await raw.close();
      await expectLater(
        page(),
        throwsA(recordingError('E_RECORDING_IDENTITY_REQUIRED')),
      );
    },
  );

  test(
    'A result in flight is fenced immediately by B identity change',
    () async {
      await seedHistory(f, [historyRecord(f, 1)]);
      // Hold owner reconciliation's transaction; identity fencing occurs before
      // queued adoption and the old page must fail instead of publishing.
      final gate = Completer<void>();
      final entered = Completer<void>();
      f.store.beforeHistoryPage = () async {
        entered.complete();
        await gate.future;
      };
      final pending = page();
      final assertion = expectLater(
        pending,
        throwsA(recordingError('E_RECORDING_UNAVAILABLE')),
      );
      await entered.future;
      final changed = f.bind(recordingUserB);
      gate.complete();
      await assertion;
      await changed;
      f.store.beforeHistoryPage = null;
      expect((await page()).items, isEmpty);
    },
  );

  for (final kind in ['app', 'backend']) {
    test('$kind scope rejects previous cursors', () async {
      await seedHistory(f, [historyRecord(f, 1), historyRecord(f, 2)]);
      final cursor = (await page(limit: 1)).nextCursor!;
      if (kind == 'backend') f.backend = 'https://different.test';
      await f.bind(
        kind == 'app'
            ? recordingUserA.copyWith(appId: 'other')
            : recordingUserA,
      );
      await expectLater(
        page(cursor: cursor),
        throwsA(recordingError('E_RECORDING_INVALID_CURSOR')),
      );
      expect((await page()).items, isEmpty);
    });
  }

  test(
    'cold canonical contradiction purges then quarantines metadata history',
    () async {
      await seedHistory(f, [historyRecord(f, 1)]);
      final dir = f.directory;
      final sessions = f.sessionStore;
      await f.dispose();
      f = await RecordingFixture.create(
        directory: dir,
        sessionStore: sessions,
        user: recordingUserA.copyWith(sdkUserId: 'contradiction'),
      );
      await expectLater(
        page(),
        throwsA(recordingError('E_RECORDING_IDENTITY_REQUIRED')),
      );
      await expectLater(
        page(),
        throwsA(recordingError('E_RECORDING_UNAVAILABLE')),
      );
      final raw = await f.raw();
      expect(await raw.query('recording_history_order'), isEmpty);
      await raw.close();
    },
  );

  test(
    'canonical conflict purges and fences history until trusted adoption',
    () async {
      await seedHistory(f, [historyRecord(f, 1)]);
      await f.bind(recordingUserA.copyWith(sdkUserId: 'contradiction'));
      expect((await page()).items, isEmpty);
    },
  );

  test(
    'cursor schema, range, encoding, owner and field types fail sanitized',
    () async {
      await seedHistory(f, [historyRecord(f, 1), historyRecord(f, 2)]);
      final cursor = (await page(limit: 1)).nextCursor!;
      final fields = jsonDecode(utf8.decode(base64Url.decode(cursor))) as List;
      String token(List<dynamic> value) =>
          base64Url.encode(utf8.encode(jsonEncode(value)));
      final invalid = <String>[
        '',
        '%%%',
        List.filled(513, 'a').join(),
        base64Url.encode([255]),
        token([]),
        token([1, fields[1], 0]),
        token([2, ...fields.skip(1)]),
        token([1.0, ...fields.skip(1)]),
        token([1, 'foreign', fields[2], fields[3]]),
        token([1, fields[1], 'bad', fields[3]]),
        token([1, fields[1], 8640000000000000001, fields[3]]),
        token([1, fields[1], fields[2], 'bad-id']),
        token([1, fields[1], fields[2], null]),
      ];
      for (final value in invalid) {
        await expectLater(
          page(cursor: value),
          throwsA(recordingError('E_RECORDING_INVALID_CURSOR')),
        );
      }
      final terminal = token([
        1,
        fields[1],
        -8640000000000000000,
        historyId(0),
      ]);
      expect((await page(cursor: terminal)).items, isEmpty);
    },
  );
}
