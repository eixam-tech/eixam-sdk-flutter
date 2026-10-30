import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'activity_recording_ingestion_test.dart' show batch, points, sample;
import 'recording_history_test_support.dart';
import 'recording_test_support.dart';

void main() {
  late RecordingHistoryHarness h;
  late RecordingFixture f;
  late SdkActivityRecording r;
  late int t;
  setUp(() async {
    h = RecordingHistoryHarness();
    await h.create();
    f = h.f;
    r = await f.start(device: tagA);
    t = f.now.millisecondsSinceEpoch ~/ 1000;
    f.now = f.now.add(const Duration(minutes: 1));
  });
  tearDown(() => h.delete());
  Future<SdkActivityRecording> current() async =>
      (await f.controller.getActiveActivityRecording())!;
  Future<void> live(int n) =>
      f.controller.ingestLive(batch(f, [h.sample(t + n, n + 1)]));
  Future<void> pending() async {
    await live(1);
    await f.controller.inputDisconnected(tagA, false);
  }

  Future<void> restore() async {
    final directory = f.directory;
    final sessions = f.sessionStore;
    await f.dispose();
    f = await RecordingFixture.create(
      directory: directory,
      sessionStore: sessions,
      backlog: h.coordinator,
    );
    f.now = DateTime.fromMillisecondsSinceEpoch((t + 60) * 1000, isUtc: true);
    h.f = f;
  }

  Future<List<SdkActivityRouteGap>> gaps() async =>
      (await f.controller
              .readActivityRecordingRoute(recordingId: r.recordingId)
              .toList())
          .expand((p) => p.gaps)
          .toList();

  test(
    'pending disconnect restores offline with route, gap, binding and recovery need',
    () async {
      await pending();
      final before = await current();
      final gap = (await gaps()).single;
      await restore();
      final after = await current();
      expect(after.recordingId, before.recordingId);
      expect(after.deviceIdentity, tagA);
      expect(after.phase, ActivityRecordingPhase.active);
      expect(after.pointCount, 1);
      expect(after.routeRevision, before.routeRevision);
      expect(after.routeQuality, ActivityRecordingRouteQuality.partial);
      expect((await gaps()).single.gapId, gap.gapId);
      expect((await gaps()).single.until, isNull);
      await pumpEventQueue();
      expect(
        (await current()).recoveryState,
        ActivityRecordingRecoveryState.deferred,
      );
      expect(h.requests, isEmpty);
    },
  );

  test(
    'recovering process loss restores durable partial chunks; older gap beats newer live cursor',
    () async {
      await pending();
      await h.ready();
      final work = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      final stopped = expectLater(
        work,
        throwsA(recordingError('E_RECORDING_UNAVAILABLE')),
      );
      await pumpEventQueue();
      await h.send(h.meta(3));
      await h.send(h.chunk(t + 2, index: 0, packet: 3));
      await live(50);
      final before = await current();
      expect(before.recoveryState, ActivityRecordingRecoveryState.recovering);
      await restore();
      await stopped;
      expect((await current()).pointCount, 3);
      expect((await current()).routeRevision, before.routeRevision);
      expect(
        (await current()).recoveryState,
        ActivityRecordingRecoveryState.deferred,
      );
      await h.ready();
      final replay = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      await pumpEventQueue();
      final since = h.requests.last.sublist(1, 5);
      expect(since, h.u32(t + 1)); // New live T50 cannot bypass unresolved T1.
      await h.send(h.meta(1));
      await h.send(h.chunk(t + 2, packet: 3));
      await h.send(h.end(1));
      final after = await replay;
      expect(after.pointCount, 3);
      expect(
        (await points(f, r.recordingId)).where((p) => p.sampledAt.second == 2),
        hasLength(1),
      );
    },
  );

  test(
    'durable completed cursor is inclusive and does not follow live samples',
    () async {
      await h.ready();
      var work = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      await pumpEventQueue();
      await h.send(h.meta(2));
      await h.send(h.chunk(t + 2));
      await h.send(h.chunk(t + 3, index: 1));
      await h.send(h.end(2));
      await work;
      await live(50);
      await restore();
      await h.ready();
      work = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      await pumpEventQueue();
      expect(h.requests.last.sublist(1, 5), h.u32(t + 3));
      await h.send(h.meta(0));
      await h.send(h.end(0));
      await work;
    },
  );

  test(
    'recording-owned deadline ends at 60s despite continuous D1 progress',
    () async {
      await pending();
      await h.ready();
      final clock = FakeAsync();
      final now = f.now;
      f.time = () => now.add(clock.elapsed);
      f.recoveryTimer = (d, cb) =>
          clock.run((_) => Timer(d, () => Zone.root.run(cb)));
      var settled = false;
      final work = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      unawaited(work.then((_) => settled = true));
      await pumpEventQueue();
      await h.send(h.meta(100));
      for (var i = 0; i < 14; i++) {
        clock.elapse(const Duration(seconds: 4));
        await pumpEventQueue();
        await h.send(h.chunk(t + 2 + i, index: i, packet: i + 3));
      }
      clock.elapse(const Duration(milliseconds: 3999));
      await pumpEventQueue();
      expect(settled, isFalse);
      clock.elapse(const Duration(milliseconds: 1));
      await pumpEventQueue();
      final result = await work;
      expect(clock.elapsed, const Duration(seconds: 60));
      expect(result.pointCount, 15);
      expect(result.recoveryState, ActivityRecordingRecoveryState.deferred);
      expect(result.issues, contains(ActivityRecordingIssue.recoveryTimedOut));
      expect(h.coordinator.isActive, isFalse);
      expect(h.requests, hasLength(1));
      final revision = result.routeRevision;
      await h.send(h.chunk(t + 20, index: 14));
      await h.send(h.end(100));
      expect((await current()).routeRevision, revision);
      clock.elapse(const Duration(minutes: 2));
      await pumpEventQueue();
      expect(h.requests, hasLength(1));
    },
  );

  test('ownership loss defers and readiness edge resumes only once', () async {
    await pending();
    await h.ready(notify: true);
    await pumpEventQueue();
    expect(h.requests, hasLength(1));
    final work = f.controller.recoverActivityRecordingHistory(
      recordingId: r.recordingId,
    );
    final fenced = expectLater(
      work,
      completion(
        isA<SdkActivityRecording>().having(
          (r) => r.recoveryState,
          'state',
          ActivityRecordingRecoveryState.deferred,
        ),
      ),
    );
    await pumpEventQueue();
    f.historyReady = false;
    f.controller.reconcileHistoryReadiness();
    await pumpEventQueue();
    await fenced;
    expect(
      (await current()).recoveryState,
      ActivityRecordingRecoveryState.deferred,
    );
    f.historyReady = true;
    f.controller.reconcileHistoryReadiness();
    await pumpEventQueue();
    expect(h.requests, hasLength(2));
    final resumed = f.controller.recoverActivityRecordingHistory(
      recordingId: r.recordingId,
    );
    await pumpEventQueue();
    await h.send(h.meta(0));
    await h.send(h.end(0));
    await resumed;
    for (var i = 0; i < 20; i++) {
      f.controller.reconcileHistoryReadiness();
    }
    await pumpEventQueue();
    expect(h.requests, hasLength(2));
    // A genuine runtime resume is a future trigger even if the command path
    // remained ready throughout the background interval.
    f.controller.reconcileHistoryReadiness(runtimeResumed: true);
    await pumpEventQueue();
    expect(h.requests, hasLength(3));
    final foreground = f.controller.recoverActivityRecordingHistory(
      recordingId: r.recordingId,
    );
    await pumpEventQueue();
    await h.send(h.meta(0));
    await h.send(h.end(0));
    expect(
      (await foreground).recoveryState,
      ActivityRecordingRecoveryState.deferred,
    );
  });

  test(
    'paused route reader permits recovered commit and rejects the new revision',
    () async {
      await pending();
      await h.ready();
      final work = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      await pumpEventQueue();
      await h.send(h.meta(1));
      final before = await current();
      final seen = <SdkActivityRoutePage>[];
      final errors = <Object>[];
      final paused = Completer<void>();
      final done = Completer<void>();
      late StreamSubscription<SdkActivityRoutePage> reader;
      reader = f.controller
          .readActivityRecordingRoute(recordingId: r.recordingId, pageSize: 1)
          .listen(
            (page) {
              seen.add(page);
              if (!page.isLast && !paused.isCompleted) {
                reader.pause();
                paused.complete();
              }
            },
            onError: errors.add,
            onDone: done.complete,
          );
      try {
        await paused.future;
        var committed = false;
        await h.send(h.chunk(t + 2)).then((_) => committed = true);
        expect(committed, isTrue);
        expect(reader.isPaused, isTrue);
        expect(seen, hasLength(1));
        expect(
          seen.every((page) => page.routeRevision == before.routeRevision),
          isTrue,
        );
        await h.send(h.end(1));
        final after = await work;
        expect(after.pointCount, 2);
        expect(after.routeRevision, greaterThan(before.routeRevision));
        expect(reader.isPaused, isTrue);
        reader.resume();
        await done.future;
        expect(seen, hasLength(1));
        expect(errors, [recordingError('E_RECORDING_ROUTE_REVISION_CHANGED')]);
      } finally {
        await reader.cancel();
      }
      await expectLater(
        f.controller
            .readActivityRecordingRoute(
              recordingId: r.recordingId,
              expectedRouteRevision: before.routeRevision,
            )
            .toList(),
        throwsA(recordingError('E_RECORDING_ROUTE_REVISION_CHANGED')),
      );
    },
  );

  test(
    'disconnect during reconciliation acknowledgement cannot heal the new gap',
    () async {
      await pending();
      f.now = DateTime.fromMillisecondsSinceEpoch((t + 10) * 1000, isUtc: true);
      await f.controller.inputDisconnected(tagA, true);
      await h.ready();
      final work = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      final fenced = expectLater(
        work,
        completion(
          isA<SdkActivityRecording>().having(
            (r) => r.recoveryState,
            'state',
            ActivityRecordingRecoveryState.deferred,
          ),
        ),
      );
      await pumpEventQueue();
      await h.send(h.meta(2));
      await h.send(h.chunk(t + 1, packet: 2));
      await h.send(h.chunk(t + 10, index: 1, packet: 11));
      final gate = Completer<void>();
      f.store.writeGate = gate;
      f.store.writeEntered = Completer<void>();
      final end = h.send(h.end(2));
      await f.store.writeEntered!.future;
      f.connected = false;
      final disconnect = f.controller.inputDisconnected(tagA, false);
      gate.complete();
      await end;
      await disconnect;
      await fenced;
      expect(
        (await current()).routeQuality,
        ActivityRecordingRouteQuality.partial,
      );
      expect(
        (await gaps()).where(
          (g) =>
              g.until == null && g.state == ActivityRecordingGapState.pending,
        ),
        hasLength(1),
      );
      expect((await current()).unresolvedGapCount, 1);
    },
  );

  test(
    'failed recovery-state commit releases episode and permits explicit retry',
    () async {
      await h.ready();
      f.store.failNextWrite = true;
      await expectLater(
        f.controller.recoverActivityRecordingHistory(
          recordingId: r.recordingId,
        ),
        throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
      );
      expect(h.requests, isEmpty);
      final retry = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      await pumpEventQueue();
      await h.send(h.meta(0));
      await h.send(h.end(0));
      expect((await retry).recoveryState, ActivityRecordingRecoveryState.idle);
      expect(h.requests, hasLength(1));
    },
  );

  test(
    'conflicting D1 identity preserves first content and cannot heal disconnect',
    () async {
      final recovered = h.sample(t + 2, 3);
      await f.controller.ingestLive(
        batch(f, [
          sample(
            recovered.stableSampleKey,
            recovered.sampledAt!,
            latitude: 41,
            longitude: 2,
          ),
        ]),
      );
      await f.controller.inputDisconnected(tagA, false);
      f.now = DateTime.fromMillisecondsSinceEpoch((t + 10) * 1000, isUtc: true);
      await f.controller.inputDisconnected(tagA, true);
      await h.ready();
      final work = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      await pumpEventQueue();
      await h.send(h.meta(2));
      await h.send(h.chunk(t + 2, packet: 3));
      await h.send(h.chunk(t + 10, index: 1));
      await h.send(h.end(2));
      final result = await work;
      expect(result.pointCount, 2);
      expect(result.unresolvedGapCount, 2);
      expect(result.routeQuality, ActivityRecordingRouteQuality.partial);
      expect((await points(f, r.recordingId)).first.latitude, 41);
      expect(
        (await gaps()).any(
          (g) => g.state == ActivityRecordingGapState.reconciled,
        ),
        isFalse,
      );
    },
  );
}
