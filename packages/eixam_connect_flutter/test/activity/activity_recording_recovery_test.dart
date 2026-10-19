import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'activity_recording_ingestion_test.dart' show batch, points;
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
    t = r.recordingStartedAt.millisecondsSinceEpoch ~/ 1000;
    f.now = f.now.add(const Duration(minutes: 1));
  });
  tearDown(() => h.delete());

  Future<SdkActivityRecording> current() async =>
      (await f.controller.getActiveActivityRecording())!;
  Future<void> live(int offset, int packet) =>
      f.controller.ingestLive(batch(f, [h.sample(t + offset, packet)]));
  Future<List<SdkActivityRouteGap>> gaps() async =>
      (await f.controller
              .readActivityRecordingRoute(recordingId: r.recordingId)
              .toList())
          .expand((p) => p.gaps)
          .toList();
  Future<void> disconnect({bool leading = false}) async {
    if (!leading) {
      await live(0, 1);
      await live(5, 2);
    }
    await f.controller.inputDisconnected(tagA, false);
  }

  Future<SdkActivityRecording> recover(
    List<int> offsets, {
    bool end = true,
  }) async {
    await h.ready();
    final future = f.controller.recoverActivityRecordingHistory(
      recordingId: r.recordingId,
    );
    await pumpEventQueue();
    await h.send(h.meta(offsets.length));
    for (var i = 0; i < offsets.length; i++) {
      await h.send(
        h.chunk(
          t + offsets[i],
          index: i,
          packet: offsets[i] == 5 ? 2 : offsets[i] + 1,
        ),
      );
    }
    if (end) await h.send(h.end(offsets.length));
    return future;
  }

  test(
    'confirmed disconnect, leading gap, wrong TAG and sparse cadence',
    () async {
      await disconnect(leading: true);
      expect((await current()).pointCount, 0);
      expect((await current()).phase, ActivityRecordingPhase.active);
      expect(
        (await current()).inputState,
        ActivityRecordingInputState.disconnected,
      );

      expect((await gaps()).single.from, r.recordingStartedAt);
      expect((await gaps()).single.until, isNull);
      expect((await gaps()).single.state, ActivityRecordingGapState.pending);
      expect(
        (await current()).routeQuality,
        ActivityRecordingRouteQuality.partial,
      );
      await f.controller.inputDisconnected(tagB, true);
      expect((await gaps()).single.until, isNull);
      await f.controller.inputDisconnected(tagA, true);
      expect((await gaps()).single.until, f.now);
      expect((await gaps()).single.state, ActivityRecordingGapState.pending);
      f.now = f.now.add(const Duration(hours: 1));
      expect(
        (await current()).inputState,
        ActivityRecordingInputState.observing,
      );
      expect(
        (await f.sessions.getActiveActivitySession())!.sessionId,
        r.activitySessionId,
      );
    },
  );

  test(
    'complete D1 anchors heal gap; live/newest-first recovery interleave canonically',
    () async {
      await disconnect();
      expect(
        (await gaps()).single.from,
        DateTime.fromMillisecondsSinceEpoch((t + 5) * 1000, isUtc: true),
      );
      f.now = DateTime.fromMillisecondsSinceEpoch((t + 10) * 1000, isUtc: true);
      await f.controller.inputDisconnected(
        tagA,
        true,
      ); // Close, but commands not ready.
      await live(10, 11);
      expect((await current()).segmentCount, greaterThan(1));
      expect(
        (await current()).recordedDistanceMeters,
        0,
      ); // Only the pre-gap edge.
      await h.ready();
      final work = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      final coalesced = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      await pumpEventQueue();
      expect(
        (await current()).recoveryState,
        ActivityRecordingRecoveryState.recovering,
      );
      await h.send(h.meta(4));
      await h.send(h.chunk(t + 10, index: 0, packet: 11));
      await h.send(h.chunk(t + 7, index: 1, packet: 8));
      await live(12, 13);
      await h.send(h.chunk(t + 6, index: 2, packet: 7));
      await h.send(h.chunk(t + 5, index: 3, packet: 2));
      await h.send(h.end(4));
      final settled = await work;
      expect((await coalesced).routeRevision, settled.routeRevision);
      expect(h.requests, hasLength(1));
      expect(settled.pointCount, 6);
      expect(settled.segmentCount, 1);
      expect(settled.unresolvedGapCount, 0);
      expect(settled.routeQuality, ActivityRecordingRouteQuality.unknown);
      expect((await gaps()).single.state, ActivityRecordingGapState.reconciled);
      expect((await points(f, r.recordingId)).map((p) => p.sampledAt.second), [
        0,
        5,
        6,
        7,
        10,
        12,
      ]);
      expect(settled.routeChangedFrom, r.recordingStartedAt);
    },
  );

  for (final offsets in [
    <int>[],
    [7],
    [5, 7],
  ]) {
    test(
      'insufficient retained anchors $offsets keep partial route and data',
      () async {
        await disconnect();
        f.now = DateTime.fromMillisecondsSinceEpoch(
          (t + 10) * 1000,
          isUtc: true,
        );
        await f.controller.inputDisconnected(tagA, true);
        await live(10, 11);
        final settled = await recover(offsets);
        expect(settled.unresolvedGapCount, 1);
        expect(settled.routeQuality, ActivityRecordingRouteQuality.partial);
        expect(settled.recoveryState, ActivityRecordingRecoveryState.deferred);
        expect(
          (await gaps()).single.state,
          ActivityRecordingGapState.unresolved,
        );
        expect(settled.pointCount, 3 + offsets.where((n) => n != 5).length);
        final revision = settled.routeRevision;
        final replay = await recover(offsets);
        expect(replay.routeRevision, revision);
      },
    );
  }

  test(
    'same D3/D1 sample and reverse delivery are durable revision no-ops',
    () async {
      await live(1, 2);
      final before = await current();
      await h.ready();
      final work = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      await pumpEventQueue();
      await h.send(h.meta(1));
      await h.send(h.chunk(t + 1, packet: 2));
      await h.send(h.end(1));
      expect((await work).routeRevision, before.routeRevision);
      final recovered = await recover([2]);
      expect(recovered.pointCount, 2);
      await live(2, 3);
      expect((await current()).routeRevision, recovered.routeRevision);
      expect(
        (await points(f, r.recordingId)).last.delivery,
        EixamDevicePositionDelivery.recovered,
      );
    },
  );

  test(
    'wrong TAG packets ignored and malformed/partial transfers retain committed chunks',
    () async {
      await disconnect();
      await h.ready();
      final clock = FakeAsync();
      f.recoveryTimer = (d, cb) =>
          clock.run((_) => Timer(d, () => Zone.root.run(cb)));
      h.onStart = () async {
        if (h.requests.length > 1) {
          throw const DeviceException(
            'E_DEVICE_BACKLOG_SYNC_OWNER_UNAVAILABLE',
            'busy',
          );
        }
      };
      final work = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      await pumpEventQueue();
      await h.send(h.meta(2), device: tagB);
      await h.send(h.chunk(t + 6), device: tagB);
      expect((await current()).pointCount, 2);
      await h.send(h.meta(2));
      await h.send(h.chunk(t + 6, index: 0, packet: 7));
      await h.send(h.chunk(t + 7, index: 3, packet: 8));
      await pumpEventQueue();
      clock.elapse(const Duration(seconds: 1));
      await pumpEventQueue();
      final settled = await work;
      expect(settled.pointCount, 3);
      expect(settled.routeQuality, ActivityRecordingRouteQuality.partial);
      expect(settled.issues, contains(ActivityRecordingIssue.recoveryFailed));
    },
  );

  test('out-of-window history never enters canonical recording', () async {
    final settled = await recover([-1, 1, 61]);
    expect(settled.pointCount, 1);
    expect(
      (await points(f, r.recordingId)).single.sampledAt,
      DateTime.fromMillisecondsSinceEpoch((t + 1) * 1000, isUtc: true),
    );
  });

  test(
    'identity change fences queued D1 commit, observers, and old recording',
    () async {
      await h.ready();
      final work = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      final expected = expectLater(
        work,
        throwsA(recordingError('E_RECORDING_UNAVAILABLE')),
      );
      await pumpEventQueue();
      await h.send(h.meta(1));
      final gate = Completer<void>();
      f.store.writeGate = gate;
      f.store.writeEntered = Completer<void>();
      final chunk = h.send(h.chunk(t + 1));
      await f.store.writeEntered!.future;
      final switching = f.bind(recordingUserB);
      gate.complete();
      await switching;
      await chunk;
      await expected;
      expect(await f.controller.getActiveActivityRecording(), isNull);
      expect(
        await f.controller.getActivityRecording(recordingId: r.recordingId),
        isNull,
      );
      final next = await f.start(device: tagB);
      await h.send(h.end(1));
      expect((await current()).recordingId, next.recordingId);
      expect((await current()).pointCount, 0);
    },
  );

  test(
    'finish fences recovery without final catch-up or finished-route mutation',
    () async {
      await h.ready();
      final work = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      final expected = expectLater(
        work,
        throwsA(recordingError('E_RECORDING_UNAVAILABLE')),
      );
      await pumpEventQueue();
      await h.send(h.meta(1));
      final done = await f.controller.finishActivityRecording(
        recordingId: r.recordingId,
      );
      await h.send(h.chunk(t + 1));
      await h.send(h.end(1));
      await expected;
      expect(done.pointCount, 0);
      expect(h.requests, hasLength(1));
      expect(
        (await f.controller.getActivityRecording(
          recordingId: r.recordingId,
        ))!.routeRevision,
        done.routeRevision,
      );
    },
  );

  test('busy public backlog is never cancelled or displaced', () async {
    await h.ready();
    final public = h.coordinator.sync(
      since: r.recordingStartedAt,
      until: f.now,
      timeout: const Duration(seconds: 5),
    );
    final deferred = await f.controller.recoverActivityRecordingHistory(
      recordingId: r.recordingId,
    );
    expect(deferred.recoveryState, ActivityRecordingRecoveryState.deferred);
    expect(h.coordinator.isActive, isTrue);
    expect(h.commands, [0x30]);
    await h.send(h.meta(0));
    await h.send(h.end(0));
    expect((await public).completed, isTrue);
  });

  test(
    'recovered middle point replaces distance edge and persists first provenance',
    () async {
      await f.controller.ingestLive(
        batch(f, [
          h.sample(t, 1, latitude: 41),
          h.sample(t + 2, 3, latitude: 41.002),
        ]),
      );
      final chord = (await current()).recordedDistanceMeters!;
      await h.ready();
      final work = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      await pumpEventQueue();
      await h.send(h.meta(1));
      await h.send(h.chunk(t + 1, latitude: 42));
      await h.send(h.end(1));
      final result = await work;
      expect(result.recordedDistanceMeters, greaterThan(chord));
      expect(result.pointCount, 3);
      expect(result.segmentCount, 1);
      expect(result.routeChangedFrom, r.recordingStartedAt);
      expect(
        (await points(f, r.recordingId))[1].delivery,
        EixamDevicePositionDelivery.recovered,
      );
    },
  );

  test(
    'invalid D1 fix is rejected and prevents a spanning transfer from healing',
    () async {
      await disconnect();
      f.now = DateTime.fromMillisecondsSinceEpoch((t + 10) * 1000, isUtc: true);
      await f.controller.inputDisconnected(tagA, true);
      await h.ready();
      final work = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      await pumpEventQueue();
      await h.send(h.meta(3));
      await h.send(h.chunk(t + 5, packet: 2));
      await h.send(h.chunk(t + 7, index: 1, invalid: true));
      await h.send(h.chunk(t + 10, index: 2));
      await h.send(h.end(3));
      final result = await work;
      expect(result.pointCount, 3);
      expect(result.unresolvedGapCount, 2);
      expect(result.routeQuality, ActivityRecordingRouteQuality.partial);
      expect(result.issues, contains(ActivityRecordingIssue.invalidSamples));
      expect(
        (await gaps()).any(
          (g) => g.state == ActivityRecordingGapState.reconciled,
        ),
        isFalse,
      );
    },
  );

  test(
    'fake clock retries immediate, 1s, 5s then exhausts without polling',
    () async {
      await h.ready();
      h.onStart = () async {
        throw StateError('transport');
      };
      await pumpEventQueue();
      final clock = FakeAsync();
      final now = f.now;
      f.time = () => now.add(clock.elapsed);
      f.recoveryTimer = (duration, callback) =>
          clock.run((_) => Timer(duration, () => Zone.root.run(callback)));
      final work = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      await pumpEventQueue();
      expect(h.requests, hasLength(1));
      clock.elapse(const Duration(milliseconds: 999));
      await pumpEventQueue();
      expect(h.requests, hasLength(1));
      clock.elapse(const Duration(milliseconds: 1));
      await pumpEventQueue();
      expect(h.requests, hasLength(2));
      clock.elapse(const Duration(seconds: 5));
      await pumpEventQueue();
      expect(h.requests, hasLength(3));
      expect(
        (await work).recoveryState,
        ActivityRecordingRecoveryState.deferred,
      );
      clock.elapse(const Duration(minutes: 3));
      await pumpEventQueue();
      expect(h.requests, hasLength(3));
    },
  );
}
