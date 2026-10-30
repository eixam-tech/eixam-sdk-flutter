import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'activity_recording_ingestion_test.dart' show batch, sample, points;
import 'recording_history_test_support.dart';
import 'recording_test_support.dart';

void main() {
  late RecordingHistoryHarness h;
  late RecordingFixture f;
  late SdkActivityRecording r;
  late int t;
  late FakeAsync clock;
  setUp(() async {
    h = RecordingHistoryHarness();
    await h.create();
    f = h.f;
    r = await f.start(device: tagA);
    t = r.recordingStartedAt.millisecondsSinceEpoch ~/ 1000;
    f.now = f.now.add(const Duration(seconds: 10));
    clock = FakeAsync();
    f.recoveryTimer = (d, cb) =>
        clock.run((_) => Timer(d, () => Zone.root.run(cb)));
  });
  tearDown(() => h.delete());

  Future<SdkActivityRecording> current() async =>
      (await f.controller.getActivityRecording(recordingId: r.recordingId))!;
  Future<SdkActivityRecording> finish({DateTime? cutoff}) => f.controller
      .finishActivityRecording(recordingId: r.recordingId, endedAt: cutoff);
  Future<void> live(int offset, int packet) =>
      f.controller.ingestLive(batch(f, [h.sample(t + offset, packet)]));
  Future<List<SdkActivityRoutePage>> route() => f.controller
      .readActivityRecordingRoute(recordingId: r.recordingId)
      .toList();
  Future<void> gap() async {
    await live(0, 1);
    await live(5, 2);
    await f.controller.inputDisconnected(tagA, false);
    await f.controller.inputDisconnected(tagA, true);
  }

  Future<void> history(List<int> offsets) async {
    await h.send(h.meta(offsets.length));
    for (var i = 0; i < offsets.length; i++) {
      final n = offsets[i];
      await h.send(h.chunk(t + n, index: i, packet: n == 5 ? 2 : n + 1));
    }
    await h.send(h.end(offsets.length));
  }

  Future<void> reopen({required DateTime now, bool ready = false}) async {
    final dir = f.directory;
    final sessions = f.sessionStore;
    await f.dispose();
    h.f = f = await RecordingFixture.create(
      directory: dir,
      sessionStore: sessions,
      backlog: h.coordinator,
    );
    f.now = now;
    f.connected = ready;
    f.historyReady = ready;
    f.recoveryTimer = (d, cb) =>
        clock.run((_) => Timer(d, () => Zone.root.run(cb)));
  }

  test(
    'connected clean finish persists cutoff first and lifecycle does not revise route',
    () async {
      await live(0, 1);
      await live(5, 2);
      final before = await current();
      await h.ready();
      final work = finish();
      await pumpEventQueue();
      final pending = await current();
      expect(pending.phase, ActivityRecordingPhase.finalizing);
      expect(pending.endedAt, f.now);
      final db = await f.raw();
      final row = (await db.query('recordings')).single;
      await db.close();
      expect(row['finalization_started_at'], f.now.toIso8601String());
      expect(
        row['finalization_deadline_at'],
        f.now.add(const Duration(seconds: 5)).toIso8601String(),
      );
      await history([]);
      final done = await work;
      expect(done.phase, ActivityRecordingPhase.finished);
      expect(done.inputState, ActivityRecordingInputState.unavailable);
      expect(done.recoveryState, ActivityRecordingRecoveryState.idle);
      expect(done.routeRevision, before.routeRevision);
      expect(done.recordedDistanceMeters, before.recordedDistanceMeters);
      expect(await f.controller.getActiveActivityRecording(), isNull);
      expect(h.requests, hasLength(1));
    },
  );

  test(
    'disconnected finish returns promptly, preserves unresolved evidence and no fallback',
    () async {
      await live(0, 1);
      await live(5, 2);
      await f.controller.inputDisconnected(tagA, false);
      final before = await current();
      final done = await finish();
      expect(clock.elapsed, Duration.zero);
      expect(h.requests, isEmpty);
      expect(done.routeQuality, ActivityRecordingRouteQuality.partial);
      expect(done.unresolvedGapCount, 1);
      expect(done.recordedDistanceMeters, before.recordedDistanceMeters);
      expect(
        (await route()).expand((p) => p.gaps).single.state,
        ActivityRecordingGapState.unresolved,
      );
    },
  );

  for (final bound in [true, false]) {
    test('no route has null distance; bound=$bound', () async {
      if (!bound) {
        await finish();
        await f.sessions.endActivitySession(sessionId: r.activitySessionId);
        r = await f.start();
      }
      final done = await finish();
      expect(done.pointCount, 0);
      expect(done.recordedDistanceMeters, isNull);
      expect(done.routeQuality, ActivityRecordingRouteQuality.unknown);
      expect(
        done.inputState,
        bound
            ? ActivityRecordingInputState.unavailable
            : ActivityRecordingInputState.unbound,
      );
      expect(done.routeRevision, 0);
    });
  }

  for (final offsets in [
    [5, 7, 10],
    [7],
    <int>[],
  ]) {
    test(
      'final history $offsets retains useful points and only proven coverage heals',
      () async {
        await gap();
        await h.ready();
        final work = finish();
        await pumpEventQueue();
        await history(offsets);
        final done = await work;
        final complete = offsets.length == 3;
        expect(done.pointCount, 2 + offsets.where((n) => n != 5).length);
        expect(done.unresolvedGapCount, complete ? 0 : 1);
        expect(
          done.routeQuality,
          complete
              ? ActivityRecordingRouteQuality.unknown
              : ActivityRecordingRouteQuality.partial,
        );
        expect(done.recoveryState, ActivityRecordingRecoveryState.idle);
      },
    );
  }

  test(
    'normal 60-second recovery coalesces under the five-second final cap',
    () async {
      await gap();
      await h.ready();
      final normal = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      normal.ignore();
      await pumpEventQueue();
      await h.send(h.meta(2));
      await h.send(h.chunk(t + 7, index: 0, packet: 8));
      final work = finish();
      await pumpEventQueue();
      clock.elapse(const Duration(milliseconds: 4999));
      await pumpEventQueue();
      expect((await current()).phase, ActivityRecordingPhase.finalizing);
      clock.elapse(const Duration(milliseconds: 1));
      await pumpEventQueue();
      final done = await work;
      expect(done.pointCount, 3);
      expect(done.phase, ActivityRecordingPhase.finished);
      expect(done.issues, contains(ActivityRecordingIssue.recoveryTimedOut));
      expect(done.routeQuality, ActivityRecordingRouteQuality.partial);
      expect(h.requests, hasLength(1));
      expect(h.coordinator.isActive, isFalse);
      final revision = done.routeRevision;
      await h.send(h.chunk(t + 8, index: 1));
      await h.send(h.end(2));
      await live(9, 10);
      expect((await current()).routeRevision, revision);
    },
  );

  test(
    'fresh final timeout retains committed chunks and never retries',
    () async {
      await gap();
      await h.ready();
      final work = finish();
      await pumpEventQueue();
      await h.send(h.meta(2));
      await h.send(h.chunk(t + 7, packet: 8));
      clock.elapse(const Duration(seconds: 5));
      await pumpEventQueue();
      final done = await work;
      expect(done.pointCount, 3);
      expect(done.recoveryState, ActivityRecordingRecoveryState.idle);
      expect(done.issues, contains(ActivityRecordingIssue.recoveryTimedOut));
      expect(done.routeQuality, ActivityRecordingRouteQuality.partial);
      clock.elapse(const Duration(minutes: 2));
      await pumpEventQueue();
      expect(h.requests, hasLength(1));
    },
  );

  test('busy unrelated public owner is not displaced or cancelled', () async {
    await gap();
    await h.ready();
    final public = h.coordinator.sync(
      since: r.recordingStartedAt,
      until: f.now,
      timeout: const Duration(seconds: 10),
    );
    final done = await finish();
    expect(done.phase, ActivityRecordingPhase.finished);
    expect(done.routeQuality, ActivityRecordingRouteQuality.partial);
    expect(
      done.issues,
      contains(ActivityRecordingIssue.commandOwnerUnavailable),
    );
    expect(h.commands, [0x30]);
    expect(h.coordinator.isActive, isTrue);
    await history([]);
    expect((await public).completed, isTrue);
  });

  test(
    'exact microsecond live cutoff is inclusive; late D3 and D1 cannot mutate finished',
    () async {
      await h.ready();
      final cutoff = f.now.subtract(const Duration(microseconds: 500));
      final work = finish(cutoff: cutoff);
      await pumpEventQueue();
      await f.controller.ingestLive(
        batch(f, [
          sample('before', cutoff.subtract(const Duration(microseconds: 1))),
          sample('equal', cutoff),
          sample('after', cutoff.add(const Duration(microseconds: 1))),
        ]),
      );
      await history([]);
      final done = await work;
      expect((await points(f, r.recordingId)).map((p) => p.stableSampleKey), [
        'before',
        'equal',
      ]);
      final before = (await route())
          .expand((p) => p.segments)
          .map(
            (s) => [
              s.segmentId,
              for (final p in s.points)
                [
                  p.stableSampleKey,
                  p.sampledAt,
                  p.latitude,
                  p.longitude,
                  p.altitudeMeters,
                  p.delivery,
                ],
            ],
          )
          .toList();
      await live(1, 50);
      await h.send(h.meta(1));
      await h.send(h.chunk(t + 2));
      await h.send(h.end(1));
      expect((await current()).routeRevision, done.routeRevision);
      expect((await current()).pointCount, 2);
      expect(
        (await route())
            .expand((p) => p.segments)
            .map(
              (s) => [
                s.segmentId,
                for (final p in s.points)
                  [
                    p.stableSampleKey,
                    p.sampledAt,
                    p.latitude,
                    p.longitude,
                    p.altitudeMeters,
                    p.delivery,
                  ],
              ],
            )
            .toList(),
        before,
      );
    },
  );

  test('D1 cutoff boundary inclusive and post-cutoff data rejected', () async {
    await h.ready();
    final work = finish();
    await pumpEventQueue();
    await history([9, 10, 11]);
    final done = await work;
    expect(done.pointCount, 2);
    expect(done.lastSampleAt, f.now);
    expect((await points(f, r.recordingId)).map((p) => p.sampledAt.second), [
      9,
      10,
    ]);
  });

  test(
    'concurrent compatible finish calls share cutoff and one recovery; changed cutoff rejected',
    () async {
      await h.ready();
      final a = finish();
      final b = finish(cutoff: f.now.toLocal());
      await pumpEventQueue();
      await expectLater(
        finish(cutoff: f.now.subtract(const Duration(seconds: 1))),
        throwsA(recordingError('E_RECORDING_INVALID_TIME')),
      );
      await history([1, 2]);
      final done = await a;
      expect(identical(done, await b), isTrue);
      expect(
        identical(done, await finish()),
        isFalse,
      ); // A fresh immutable SQL projection.
      expect(
        (await finish(cutoff: done.endedAt)).routeRevision,
        done.routeRevision,
      );
      await expectLater(
        finish(cutoff: f.now.add(const Duration(seconds: 1))),
        throwsA(recordingError('E_RECORDING_INVALID_TIME')),
      );
      expect(h.requests, hasLength(1));
    },
  );

  test(
    'finish after logical session End accepts the persisted earlier cutoff',
    () async {
      await live(0, 1);
      await live(9, 2);
      final cutoff = f.now.subtract(const Duration(seconds: 2));
      await f.sessions.endActivitySession(sessionId: r.activitySessionId);
      await h.ready();
      final work = finish(cutoff: cutoff);
      await pumpEventQueue();
      await history([5, 8, 9]);
      final done = await work;
      expect(done.endedAt, cutoff);
      expect(done.pointCount, 3);
      expect(done.lastSampleAt, cutoff);
      expect(done.activitySessionId, r.activitySessionId);
      expect(await f.sessions.getActiveActivitySession(), isNull);
    },
  );

  test(
    'persistence barrier drains an accepted chunk before final commit at deadline',
    () async {
      await h.ready();
      final work = finish();
      await pumpEventQueue();
      await h.send(h.meta(1));
      final gate = Completer<void>();
      f.store.writeGate = gate;
      f.store.writeEntered = Completer<void>();
      final chunk = h.send(h.chunk(t + 1));
      await f.store.writeEntered!.future;
      clock.elapse(const Duration(seconds: 5));
      gate.complete();
      await chunk;
      final done = await work;
      expect(done.pointCount, 1);
      expect((await points(f, r.recordingId)).length, 1);
      expect((await current()).routeRevision, done.routeRevision);
    },
  );

  for (final boundary in [
    'cutoff',
    'recovery',
    'chunk',
    'settled',
    'finished',
  ]) {
    test(
      'crash/ack boundary $boundary restores authoritative cutoff and committed points',
      () async {
        await h.ready();
        final cutoff = f.now;
        if (boundary == 'cutoff') {
          f.store.onCommit = (_) {
            f.store.onCommit = null;
            unawaited(f.controller.dispose());
          };
        }
        if (boundary == 'settled') {
          f.store.failPhase = ActivityRecordingPhase.finished;
        }
        if (boundary == 'finished') {
          f.store.loseAcknowledgementPhase = ActivityRecordingPhase.finished;
        }
        final work = finish();
        work.ignore();
        await pumpEventQueue();
        if (boundary == 'chunk' ||
            boundary == 'settled' ||
            boundary == 'finished') {
          await h.send(h.meta(1));
          await h.send(h.chunk(t + 1));
          if (boundary != 'chunk') await h.send(h.end(1));
        }
        if (boundary == 'settled') {
          await expectLater(
            work,
            throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
          );
        }
        if (boundary == 'finished') {
          expect((await work).phase, ActivityRecordingPhase.finished);
        }
        if (boundary == 'cutoff') {
          await expectLater(
            work,
            throwsA(recordingError('E_RECORDING_UNAVAILABLE')),
          );
          await reopen(now: cutoff.add(const Duration(seconds: 6)));
          await f.controller.getActiveActivityRecording();
          await pumpEventQueue();
        }
        final count = (await current()).pointCount;
        final pending = (await current()).phase;
        await reopen(now: cutoff.add(const Duration(seconds: 6)));
        if (boundary == 'recovery' || boundary == 'chunk') {
          await expectLater(
            work,
            throwsA(recordingError('E_RECORDING_UNAVAILABLE')),
          );
        }
        await f.controller.getActiveActivityRecording();
        await pumpEventQueue();
        final done = await finish();
        expect(done.phase, ActivityRecordingPhase.finished);
        expect(done.endedAt, cutoff);
        expect(done.pointCount, count);
        expect((await points(f, r.recordingId)).length, count);
        expect(await f.controller.getActiveActivityRecording(), isNull);
        expect(pending, isNotNull);
      },
    );
  }

  for (final shift in [3, 6, -1, 3600]) {
    test(
      'restart deadline shift $shift seconds uses only remaining budget or no wait',
      () async {
        await h.ready();
        final cutoff = f.now;
        f.store.onCommit = (_) {
          f.store.onCommit = null;
          unawaited(f.controller.dispose());
        };
        await expectLater(
          finish(),
          throwsA(recordingError('E_RECORDING_UNAVAILABLE')),
        );
        await reopen(now: cutoff.add(Duration(seconds: shift)), ready: true);
        await f.controller.getActiveActivityRecording();
        await pumpEventQueue();
        if (shift == 3) {
          expect((await current()).phase, ActivityRecordingPhase.finalizing);
          clock.elapse(const Duration(milliseconds: 1999));
          await pumpEventQueue();
          expect((await current()).phase, ActivityRecordingPhase.finalizing);
          clock.elapse(const Duration(milliseconds: 1));
          await pumpEventQueue();
        }
        final done = await finish();
        expect(done.phase, ActivityRecordingPhase.finished);
        expect(done.endedAt, cutoff);
        expect(h.requests.length, shift == 3 ? 1 : 0);
        if (shift < 0) {
          expect(done.issues, contains(ActivityRecordingIssue.clockUncertain));
        }
      },
    );
  }

  test(
    'runtime clock rollback cannot extend five-second monotonic timer',
    () async {
      await h.ready();
      final cutoff = f.now;
      final work = finish();
      await pumpEventQueue();
      f.now = f.now.subtract(const Duration(days: 2));
      clock.elapse(const Duration(seconds: 5));
      await pumpEventQueue();
      expect((await work).endedAt, cutoff);
      expect((await current()).phase, ActivityRecordingPhase.finished);
    },
  );

  test(
    'identity change fences finish, old D1 and every A observer result',
    () async {
      await h.ready();
      final seen = <SdkActivityRecording?>[];
      final sub = f.controller.watchActiveActivityRecording().listen(
        seen.add,
        onError: (_) {},
      );
      final work = finish();
      final failure = expectLater(
        work,
        throwsA(recordingError('E_RECORDING_UNAVAILABLE')),
      );
      await pumpEventQueue();
      await h.send(h.meta(1));
      await f.bind(recordingUserB);
      seen.clear();
      await h.send(h.chunk(t + 1));
      await h.send(h.end(1));
      await failure;
      await pumpEventQueue();
      expect(seen.whereType<SdkActivityRecording>(), isEmpty);
      expect(
        await f.controller.getActivityRecording(recordingId: r.recordingId),
        isNull,
      );
      expect(await f.controller.getActiveActivityRecording(), isNull);
      await sub.cancel();
    },
  );

  test(
    'adopted recovery cannot heal using a committed anchor removed by explicit cutoff',
    () async {
      await gap();
      await h.ready();
      final normal = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      await pumpEventQueue();
      await h.send(h.meta(2));
      await h.send(h.chunk(t + 5, packet: 2));
      await h.send(h.chunk(t + 10, index: 1, packet: 11));
      final work = finish(cutoff: f.now.subtract(const Duration(seconds: 2)));
      await pumpEventQueue();
      await h.send(h.end(2));
      await normal;
      final done = await work;
      expect(done.pointCount, 2);
      expect(done.unresolvedGapCount, 1);
      expect(done.routeQuality, ActivityRecordingRouteQuality.partial);
      expect(
        (await route()).expand((p) => p.gaps).single.state,
        ActivityRecordingGapState.unresolved,
      );
      expect(done.lastSampleAt!.isAfter(done.endedAt!), isFalse);
    },
  );

  test(
    'lost cutoff acknowledgement reads durable intent and finishes in same call',
    () async {
      f.store.loseNextWriteAcknowledgement = true;
      final done = await finish();
      expect(done.phase, ActivityRecordingPhase.finished);
      expect(done.endedAt, f.now);
      expect(h.requests, isEmpty);
    },
  );

  for (final failure in ['recovering projection', 'settlement']) {
    test(
      'transient $failure write failure still commits an honest partial result',
      () async {
        await gap();
        await h.ready();
        if (failure == 'recovering projection') {
          f.store.onCommit = (_) {
            f.store.onCommit = null;
            f.store.failNextWrite = true;
          };
        }
        final work = finish();
        await pumpEventQueue();
        if (failure == 'settlement') {
          await h.send(h.meta(1));
          await h.send(h.chunk(t + 7, packet: 8));
          f.store.failNextWrite = true;
          await h.send(h.end(1));
        }
        final done = await work;
        expect(done.phase, ActivityRecordingPhase.finished);
        expect(done.routeQuality, ActivityRecordingRouteQuality.partial);
        expect(done.issues, contains(ActivityRecordingIssue.recoveryFailed));
        expect(done.pointCount, failure == 'settlement' ? 3 : 2);
        expect(done.recoveryState, ActivityRecordingRecoveryState.idle);
      },
    );
  }

  test(
    'recovering projection delayed beyond deadline cannot start a backlog command',
    () async {
      await h.ready();
      final gate = Completer<void>();
      final entered = Completer<void>();
      f.store.onCommit = (_) {
        f.store.onCommit = null;
        f.store.writeGate = gate;
        f.store.writeEntered = entered;
      };
      final work = finish();
      await entered.future;
      clock.elapse(const Duration(seconds: 5));
      gate.complete();
      final done = await work;
      expect(done.phase, ActivityRecordingPhase.finished);
      expect(h.requests, isEmpty);
      expect(h.commands, isEmpty);
    },
  );

  test('A B C routes remain immutable after restart and starting D', () async {
    final results = <SdkActivityRecording>[];
    final routes = <List<String>>[];
    for (var i = 0; i < 3; i++) {
      if (i > 0) {
        r = await f.start(device: tagA);
        t = r.recordingStartedAt.millisecondsSinceEpoch ~/ 1000;
        f.now = f.now.add(const Duration(seconds: 10));
      }
      await live(0, 1);
      await live(5, 2);
      results.add(await finish());
      routes.add(
        (await points(f, r.recordingId))
            .map(
              (p) =>
                  '${p.stableSampleKey}/${p.sampledAt}/${p.latitude}/${p.longitude}',
            )
            .toList(),
      );
      await f.sessions.endActivitySession(sessionId: r.activitySessionId);
      f.now = f.now.add(const Duration(seconds: 20));
    }
    await reopen(now: f.now);
    final d = await f.start(device: tagA);
    for (var i = 0; i < results.length; i++) {
      final old = results[i];
      final read = (await f.controller.getActivityRecording(
        recordingId: old.recordingId,
      ))!;
      expect(read.routeRevision, old.routeRevision);
      expect(read.recordedDistanceMeters, old.recordedDistanceMeters);
      expect(
        (await points(f, old.recordingId))
            .map(
              (p) =>
                  '${p.stableSampleKey}/${p.sampledAt}/${p.latitude}/${p.longitude}',
            )
            .toList(),
        routes[i],
      );
      expect(
        (await f.controller.finishActivityRecording(
          recordingId: old.recordingId,
        )).endedAt,
        old.endedAt,
      );
    }
    expect(
      (await f.controller.getActiveActivityRecording())!.recordingId,
      d.recordingId,
    );
  });
}
