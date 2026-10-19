import 'dart:async';
import 'dart:math' as math;

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'recording_test_support.dart';

EixamDevicePositionSample sample(
  String key,
  DateTime at, {
  double latitude = 0,
  double longitude = 1,
  double? altitude = 40,
  SdkLocationSource source = SdkLocationSource.connectedDevice,
}) => EixamDevicePositionSample(
  latitude: latitude,
  longitude: longitude,
  altitudeMeters: altitude,
  sampledAt: at,
  packetId: 1,
  source: source,
  stableSampleKey: key,
);

EixamDevicePositionBatch batch(
  RecordingFixture f,
  List<EixamDevicePositionSample> samples, {
  String? device = tagA,
  SdkLocationSource source = SdkLocationSource.connectedDevice,
  EixamDevicePositionDelivery delivery = EixamDevicePositionDelivery.live,
}) => EixamDevicePositionBatch(
  samples: samples,
  receivedAt: f.now,
  source: source,
  delivery: delivery,
  deviceIdentity: device,
);

Future<List<SdkActivityRoutePoint>> points(
  RecordingFixture f,
  String id,
) async =>
    (await f.controller.readActivityRecordingRoute(recordingId: id).toList())
        .expand((p) => p.segments)
        .expand((s) => s.points)
        .toList();

void main() {
  late RecordingFixture f;
  late SdkActivityRecording r;
  late DateTime start;
  setUp(() async {
    f = await RecordingFixture.create();
    r = await f.start(device: tagA);
    start = r.recordingStartedAt;
    f.now = start.add(const Duration(hours: 1));
  });
  tearDown(() => f.delete());
  Future<SdkActivityRecording> current() async =>
      (await f.controller.getActiveActivityRecording())!;
  Future<void> ingest(List<EixamDevicePositionSample> samples) =>
      f.controller.ingestLive(batch(f, samples));

  test(
    'null zero horizontal distance and coalesced committed batch revision',
    () async {
      expect((await current()).recordedDistanceMeters, isNull);
      await ingest([sample('a', start)]);
      expect((await current()).recordedDistanceMeters, isNull);
      await ingest([
        sample('b', start.add(const Duration(seconds: 1)), altitude: 500),
      ]);
      expect((await current()).recordedDistanceMeters, 0.0);
      await ingest([
        sample('c', start.add(const Duration(seconds: 2)), longitude: 2),
        sample('d', start.add(const Duration(seconds: 3)), longitude: 3),
      ]);
      final state = await current();
      expect(state.pointCount, 4);
      expect(state.segmentCount, 1);
      expect(state.routeRevision, 3);
      expect(state.previousRouteRevision, 2);
      expect(
        state.recordedDistanceMeters,
        closeTo(6371000 * math.pi / 90, 1e-7),
      );
      expect(state.routeChangedFrom, start.add(const Duration(seconds: 1)));
      expect(state.inputState, ActivityRecordingInputState.observing);
      expect(state.routeQuality, ActivityRecordingRouteQuality.unknown);
    },
  );

  test(
    'out of order replaces the old neighbour edge and reads chronological',
    () async {
      final a = sample('a', start, latitude: 1, longitude: 1);
      final c = sample(
        'c',
        start.add(const Duration(seconds: 2)),
        latitude: 1,
        longitude: 3,
      );
      final b = sample(
        'b',
        start.add(const Duration(seconds: 1)),
        latitude: 2,
        longitude: 2,
      );
      await ingest([c, a]);
      final direct = (await current()).recordedDistanceMeters!;
      await ingest([b]);
      final state = await current();
      expect(state.recordedDistanceMeters, greaterThan(direct));
      expect(state.recordedDistanceMeters, closeTo(314450.86407614534, 0.01));
      expect((await points(f, r.recordingId)).map((p) => p.stableSampleKey), [
        'a',
        'b',
        'c',
      ]);
      expect(state.routeChangedFrom, start);
      expect(state.routeRevision, 2);
    },
  );

  test(
    'duplicates in and across batches and restart are durable no-ops',
    () async {
      final a = sample('a', start);
      final b = sample(
        'b',
        start.add(const Duration(seconds: 1)),
        longitude: 2,
      );
      await ingest([a, b, a]);
      final state = await current();
      await ingest([b, a]);
      expect((await current()).routeRevision, state.routeRevision);
      final directory = f.directory;
      final sessions = f.sessionStore;
      await f.dispose();
      f = await RecordingFixture.create(
        directory: directory,
        sessionStore: sessions,
      );
      f.now = start.add(const Duration(hours: 1));
      expect(
        (await current()).inputState,
        ActivityRecordingInputState.disconnected,
      );
      await ingest([a, b]);
      expect(
        (await current()).inputState,
        ActivityRecordingInputState.observing,
      );
      expect((await current()).pointCount, 2);
      expect(
        (await current()).recordedDistanceMeters,
        state.recordedDistanceMeters,
      );
      expect((await current()).routeRevision, state.routeRevision);
    },
  );

  test(
    'conflicting key preserves first value, declares integrity gap and removes crossed edge',
    () async {
      await ingest([
        sample('a', start),
        sample('b', start.add(const Duration(seconds: 2)), longitude: 2),
      ]);
      await ingest([sample('a', start, longitude: 10)]);
      final state = await current();
      expect(state.pointCount, 2);
      expect(state.recordedDistanceMeters, isNull);
      expect(state.segmentCount, 2);
      expect(state.unresolvedGapCount, 1);
      expect(state.routeQuality, ActivityRecordingRouteQuality.partial);
      expect((await points(f, r.recordingId)).first.longitude, 1);
      final revision = state.routeRevision;
      await ingest([sample('a', start, longitude: 10)]);
      expect((await current()).routeRevision, revision);
    },
  );

  test(
    'same timestamp retains both keys but never bridges ambiguous movement',
    () async {
      await ingest([
        sample('a', start),
        sample('c', start.add(const Duration(seconds: 2)), longitude: 3),
      ]);
      await ingest([sample('b', start, longitude: 2)]);
      final state = await current();
      expect(state.pointCount, 3);
      expect(state.segmentCount, 3);
      expect(state.recordedDistanceMeters, isNull);
      expect(state.unresolvedGapCount, 1);
      expect(state.issues, contains(ActivityRecordingIssue.clockUncertain));
      expect((await points(f, r.recordingId)).map((p) => p.stableSampleKey), [
        'a',
        'b',
        'c',
      ]);
    },
  );

  test(
    'known rejected in-window fix splits continuity, long sparse interval does not',
    () async {
      await ingest([
        sample('a', start),
        sample('c', start.add(const Duration(minutes: 30)), longitude: 2),
      ]);
      expect((await current()).segmentCount, 1);
      await ingest([
        sample(
          'bad',
          start.add(const Duration(minutes: 10)),
          latitude: double.nan,
        ),
      ]);
      final state = await current();
      expect(state.segmentCount, 2);
      expect(state.recordedDistanceMeters, isNull);
      expect(state.unresolvedGapCount, 1);
      expect(state.issues, contains(ActivityRecordingIssue.invalidSamples));
    },
  );

  test(
    'wrong TAG, unbound, missing canonical identity and ineligible sources make no route mutation',
    () async {
      final a = sample('a', start);
      for (final b in [
        batch(f, [a], device: tagB),
        batch(f, [a], device: null),
        batch(f, [a], source: SdkLocationSource.phone),
        batch(f, [a], delivery: EixamDevicePositionDelivery.recovered),
      ]) {
        await f.controller.ingestLive(b);
      }
      expect((await current()).pointCount, 0);
      expect((await current()).routeRevision, 0);
      await f.controller.finishActivityRecording(recordingId: r.recordingId);
      await f.sessions.endActivitySession(sessionId: r.activitySessionId);
      r = await f.start();
      await ingest([sample('x', f.now)]);
      expect((await current()).pointCount, 0);
    },
  );

  test('timestamp and geo boundary rejects never use reception time', () async {
    await ingest([
      sample('before', start.subtract(const Duration(microseconds: 1))),
      sample('future', f.now.add(const Duration(minutes: 11))),
      const EixamDevicePositionSample(
        latitude: 1,
        longitude: 1,
        altitudeMeters: null,
        sampledAt: null,
        packetId: 1,
        source: SdkLocationSource.connectedDevice,
        stableSampleKey: 'classic',
      ),
      sample('phone', start, source: SdkLocationSource.phone),
    ]);
    expect((await current()).routeRevision, 0);
    await ingest([sample('exact', start)]);
    expect((await current()).pointCount, 1);
    await ingest([
      sample(
        'nullisland',
        start.add(const Duration(seconds: 1)),
        latitude: 0,
        longitude: 0,
      ),
    ]);
    expect((await current()).pointCount, 1);
    expect((await current()).unresolvedGapCount, 1);
  });

  test(
    'microsecond order uses integer chronology independent of ISO precision',
    () async {
      await ingest([
        sample(
          'later',
          start.add(const Duration(microseconds: 1)),
          longitude: 2,
        ),
        sample('first', start),
      ]);
      expect((await points(f, r.recordingId)).map((p) => p.stableSampleKey), [
        'first',
        'later',
      ]);
      expect((await current()).firstSampleAt, start);
    },
  );

  test(
    'rollback advances no durable identity/revision and exact replay can retry',
    () async {
      final a = sample('a', start);
      f.store.failNextWrite = true;
      await expectLater(
        ingest([a]),
        throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
      );
      expect((await current()).pointCount, 0);
      expect((await current()).routeRevision, 0);
      await ingest([a]);
      expect((await current()).pointCount, 1);
      expect((await current()).routeRevision, 1);
    },
  );

  test(
    'ambiguous commit acknowledgement reconciles authoritative route without double distance',
    () async {
      final samples = [
        sample('a', start),
        sample('b', start.add(const Duration(seconds: 1)), longitude: 2),
      ];
      f.store.loseNextWriteAcknowledgement = true;
      await expectLater(
        ingest(samples),
        throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
      );
      final state = await current();
      expect(state.pointCount, 2);
      expect(state.routeRevision, 1);
      await ingest(samples);
      expect(
        (await current()).recordedDistanceMeters,
        state.recordedDistanceMeters,
      );
      expect((await current()).routeRevision, 1);
    },
  );

  test(
    'finished cutoff trims later data atomically and later deliveries cannot mutate route',
    () async {
      await ingest([
        sample('a', start),
        sample('b', start.add(const Duration(seconds: 1)), longitude: 2),
        sample('c', start.add(const Duration(seconds: 2)), longitude: 3),
      ]);
      final end = start.add(const Duration(seconds: 1));
      final result = await f.controller.finishActivityRecording(
        recordingId: r.recordingId,
        endedAt: end,
      );
      expect(result.pointCount, 2);
      expect(result.lastSampleAt, end);
      expect(result.routeRevision, 2);
      await ingest([sample('d', end, longitude: 4)]);
      expect(
        (await f.controller.getActivityRecording(
          recordingId: r.recordingId,
        ))!.pointCount,
        2,
      );
      expect((await points(f, r.recordingId)).length, 2);
    },
  );

  test(
    'small pages preserve segment ID, suffix gap context and expected revision',
    () async {
      await ingest(
        List.generate(
          5,
          (i) => sample(
            'p$i',
            start.add(Duration(seconds: i)),
            longitude: 1 + i / 10,
          ),
        ),
      );
      final pages = await f.controller
          .readActivityRecordingRoute(recordingId: r.recordingId, pageSize: 2)
          .toList();
      expect(pages.length, 3);
      expect(pages.last.isLast, isTrue);
      expect(
        pages.expand((p) => p.segments).map((s) => s.segmentId).toSet().length,
        1,
      );
      expect(pages.expand((p) => p.segments).expand((s) => s.points).length, 5);
      final suffix = await f.controller
          .readActivityRecordingRoute(
            recordingId: r.recordingId,
            fromInclusive: start.add(const Duration(seconds: 2)),
            expectedRouteRevision: 1,
            pageSize: 1,
          )
          .toList();
      expect(
        suffix.expand((p) => p.segments).expand((s) => s.points).length,
        3,
      );
      await expectLater(
        f.controller
            .readActivityRecordingRoute(
              recordingId: r.recordingId,
              expectedRouteRevision: 0,
            )
            .drain<void>(),
        throwsA(recordingError('E_RECORDING_ROUTE_REVISION_CHANGED')),
      );
    },
  );

  test(
    'paused page cancellation promptly releases transaction to the next writer',
    () async {
      await ingest(
        List.generate(5, (i) => sample('p$i', start.add(Duration(seconds: i)))),
      );
      final first = Completer<void>();
      late StreamSubscription<SdkActivityRoutePage> sub;
      sub = f.controller
          .readActivityRecordingRoute(recordingId: r.recordingId, pageSize: 1)
          .listen((page) {
            sub.pause();
            first.complete();
          });
      await first.future;
      final pending = ingest([
        sample('p5', start.add(const Duration(seconds: 5))),
      ]);
      await sub.cancel().timeout(const Duration(seconds: 2));
      await pending.timeout(const Duration(seconds: 2));
      expect((await current()).pointCount, 6);
    },
  );

  test(
    'identity replacement fences delayed writes and clears route coordinates',
    () async {
      await ingest([sample('a', start)]);
      f.store.writeGate = Completer<void>();
      f.store.writeEntered = Completer<void>();
      final gate = f.store.writeGate!;
      final pending = ingest([
        sample('b', start.add(const Duration(seconds: 1))),
      ]);
      final failed = expectLater(
        pending,
        throwsA(recordingError('E_RECORDING_UNAVAILABLE')),
      );
      await f.store.writeEntered!.future;
      final changed = f.bind(recordingUserB);
      gate.complete();
      await failed;
      await changed;
      expect(
        await f.controller.getActivityRecording(recordingId: r.recordingId),
        isNull,
      );
      final raw = await f.raw();
      expect(
        (await raw.rawQuery(
          'SELECT COUNT(*) AS n FROM route_points',
        )).single['n'],
        0,
      );
      await raw.close();
    },
  );
  test(
    'one revision stays consistent while a writer queues between pages',
    () async {
      await ingest(
        List.generate(8, (i) => sample('p$i', start.add(Duration(seconds: i)))),
      );
      Future<void>? pending;
      var delivered = 0;
      final pages = await f.controller
          .readActivityRecordingRoute(recordingId: r.recordingId, pageSize: 1)
          .map((page) {
            if (delivered++ == 0) {
              pending = ingest([
                sample('new', start.add(const Duration(seconds: 10))),
              ]);
            }
            return page;
          })
          .toList();
      expect(pages.every((p) => p.routeRevision == 1), isTrue);
      expect(pages.expand((p) => p.segments).expand((s) => s.points).length, 8);
      await pending;
      expect((await current()).pointCount, 9);
      expect((await current()).routeRevision, 2);
    },
  );

  test(
    'overlapping gap context survives suffix paging and no boundary points duplicate',
    () async {
      await ingest([
        sample('a', start),
        sample('b', start.add(const Duration(seconds: 10)), longitude: 2),
        sample('c', start.add(const Duration(seconds: 11)), longitude: 3),
      ]);
      await ingest([
        sample('a', start.add(const Duration(seconds: 10)), longitude: 7),
      ]);
      final pages = await f.controller
          .readActivityRecordingRoute(
            recordingId: r.recordingId,
            fromInclusive: start.add(const Duration(seconds: 5)),
            pageSize: 1,
          )
          .toList();
      expect(pages.expand((p) => p.gaps).length, 1);
      expect(pages.expand((p) => p.gaps).single.from, start);
      expect(
        pages
            .expand((p) => p.segments)
            .expand((s) => s.points)
            .map((p) => p.stableSampleKey),
        ['b', 'c'],
      );
    },
  );

  test(
    'current identity change cancels a paused snapshot without waiting for resume',
    () async {
      await ingest(
        List.generate(5, (i) => sample('p$i', start.add(Duration(seconds: i)))),
      );
      final first = Completer<void>();
      late StreamSubscription<SdkActivityRoutePage> sub;
      sub = f.controller
          .readActivityRecordingRoute(recordingId: r.recordingId, pageSize: 1)
          .listen((page) {
            sub.pause();
            first.complete();
          });
      await first.future;
      await f.bind(recordingUserB).timeout(const Duration(seconds: 2));
      await sub.cancel();
      expect(await f.controller.getActiveActivityRecording(), isNull);
    },
  );

  test(
    'summary insert failure after points rolls back points and dedupe',
    () async {
      final raw = await f.raw();
      await raw.execute(
        '''CREATE TRIGGER fail_route_summary BEFORE UPDATE ON recordings
      WHEN NEW.point_count > OLD.point_count BEGIN SELECT RAISE(ABORT, 'synthetic summary failure'); END''',
      );
      await raw.close();
      final errors = <Object>[];
      final sub = f.controller.watchActiveActivityRecording().listen(
        (_) {},
        onError: errors.add,
      );
      await pumpEventQueue();
      await expectLater(
        ingest([sample('retry', start)]),
        throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
      );
      expect((await current()).routeRevision, 0);
      expect(await points(f, r.recordingId), isEmpty);
      expect(
        errors.single.toString(),
        isNot(contains('synthetic summary failure')),
      );
      final repair = await f.raw();
      await repair.execute('DROP TRIGGER fail_route_summary');
      await repair.close();
      await ingest([sample('retry', start)]);
      expect((await current()).pointCount, 1);
      await sub.cancel();
    },
  );

  test(
    'observers see one complete committed batch and no speculative summary',
    () async {
      final observed = <SdkActivityRecording?>[];
      final sub = f.controller.watchActiveActivityRecording().listen(
        observed.add,
      );
      await pumpEventQueue();
      f.store.writeGate = Completer<void>();
      f.store.writeEntered = Completer<void>();
      final gate = f.store.writeGate!;
      final write = ingest(
        List.generate(
          24,
          (i) => sample(
            'p$i',
            start.add(Duration(seconds: i)),
            longitude: 1 + i / 100,
          ),
        ),
      );
      await f.store.writeEntered!.future;
      expect(
        observed.whereType<SdkActivityRecording>().every(
          (v) => v.pointCount == 0,
        ),
        isTrue,
      );
      gate.complete();
      await write;
      await pumpEventQueue();
      final route = observed
          .whereType<SdkActivityRecording>()
          .where((r) => r.pointCount > 0)
          .toList();
      expect(route.length, 1);
      expect(route.single.pointCount, 24);
      expect(route.single.routeRevision, 1);
      expect(route.single.recordedDistanceMeters, isNotNull);
      await sub.cancel();
    },
  );

  test(
    'two finished routes keep their own summary distance and points across reconstruction',
    () async {
      await ingest([
        sample('a', start),
        sample('b', start.add(const Duration(seconds: 1)), longitude: 2),
      ]);
      final a = await f.controller.finishActivityRecording(
        recordingId: r.recordingId,
      );
      await f.sessions.endActivitySession(sessionId: r.activitySessionId);
      final b = await f.start(device: tagB);
      final bStart = b.recordingStartedAt;
      f.now = bStart.add(const Duration(hours: 1));
      await f.controller.ingestLive(
        batch(f, [
          sample('x', bStart, latitude: 10, longitude: 10),
          sample(
            'y',
            bStart.add(const Duration(seconds: 1)),
            latitude: 10,
            longitude: 12,
          ),
        ], device: tagB),
      );
      final finishedB = await f.controller.finishActivityRecording(
        recordingId: b.recordingId,
      );
      final directory = f.directory;
      final sessions = f.sessionStore;
      await f.dispose();
      f = await RecordingFixture.create(
        directory: directory,
        sessionStore: sessions,
      );
      for (final expected in [a, finishedB]) {
        final restored = (await f.controller.getActivityRecording(
          recordingId: expected.recordingId,
        ))!;
        expect(restored.pointCount, 2);
        expect(
          restored.recordedDistanceMeters,
          expected.recordedDistanceMeters,
        );
        expect((await points(f, expected.recordingId)).length, 2);
      }
      expect((await points(f, a.recordingId)).first.latitude, 0);
      expect((await points(f, b.recordingId)).first.latitude, 10);
    },
  );

  test(
    'finalizing crash restores the already clipped route and rejects post-cutoff live samples',
    () async {
      await ingest([
        sample('a', start),
        sample('b', start.add(const Duration(seconds: 1)), longitude: 2),
      ]);
      f.store.failPhase = ActivityRecordingPhase.finished;
      await expectLater(
        f.controller.finishActivityRecording(
          recordingId: r.recordingId,
          endedAt: start,
        ),
        throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
      );
      await ingest([
        sample('later', start.add(const Duration(microseconds: 1))),
      ]);
      final directory = f.directory;
      final sessions = f.sessionStore;
      await f.dispose();
      f = await RecordingFixture.create(
        directory: directory,
        sessionStore: sessions,
      );
      await f.controller.getActiveActivityRecording();
      await pumpEventQueue();
      expect(await f.controller.getActiveActivityRecording(), isNull);
      final restored = (await f.controller.getActivityRecording(
        recordingId: r.recordingId,
      ))!;
      expect(restored.phase, ActivityRecordingPhase.finished);
      expect(restored.pointCount, 1);
      expect(restored.recordedDistanceMeters, isNull);
      expect((await points(f, r.recordingId)).single.stableSampleKey, 'a');
    },
  );

  for (final scenario in ['logout', 'app', 'backend', 'canonical']) {
    test(
      'route ownership cleanup preserves privacy on $scenario replacement',
      () async {
        await ingest([
          sample('a', start),
          sample(
            'bad',
            start.add(const Duration(seconds: 1)),
            latitude: double.infinity,
          ),
        ]);
        if (scenario == 'backend') {
          f.backend = 'https://another.test';
          await f.bind(recordingUserA);
        }
        if (scenario == 'app') {
          await f.bind(recordingUserA.copyWith(appId: 'another-app'));
        }
        if (scenario == 'canonical') {
          await f.bind(recordingUserA.copyWith(sdkUserId: 'contradiction'));
        }
        if (scenario == 'logout') {
          await f.bind(null);
        }
        final raw = await f.raw();
        for (final table in ['route_points', 'route_gaps', 'recordings']) {
          expect(
            (await raw.rawQuery(
              'SELECT COUNT(*) AS n FROM $table',
            )).single['n'],
            0,
          );
        }
        await raw.close();
      },
    );
  }

  test(
    'duplicate key altitude conflict is integrity evidence without movement overwrite',
    () async {
      await ingest([sample('a', start, altitude: 40)]);
      await ingest([sample('a', start, altitude: 80)]);
      expect((await current()).pointCount, 1);
      expect((await current()).unresolvedGapCount, 1);
      expect((await points(f, r.recordingId)).single.altitudeMeters, 40);
    },
  );

  test(
    'mixed reversed burst is deterministic and every non-TAG source is excluded',
    () async {
      for (final source in SdkLocationSource.values.where(
        (s) => s != SdkLocationSource.connectedDevice,
      )) {
        await f.controller.ingestLive(
          batch(f, [sample('foreign', start)], source: source),
        );
      }
      final accepted = List.generate(
        24,
        (i) => sample(
          'p${i.toString().padLeft(2, '0')}',
          start.add(Duration(seconds: i)),
        ),
      );
      await ingest([
        ...accepted.reversed,
        accepted.first,
        sample(
          'bad',
          start.add(const Duration(seconds: 12, microseconds: 1)),
          latitude: 91,
        ),
      ]);
      expect((await current()).pointCount, 24);
      expect((await current()).routeRevision, 1);
      expect((await current()).segmentCount, 2);
      expect((await current()).unresolvedGapCount, 1);
      expect(
        (await points(f, r.recordingId)).map((p) => p.stableSampleKey),
        accepted.map((p) => p.stableSampleKey),
      );
    },
  );
  test(
    'actual SQLite full during route insert rolls back and exact sample retries after capacity returns',
    () async {
      await f.delete();
      final factory = _CapacityFactory();
      f = await RecordingFixture.create(factory: factory);
      r = await f.start(device: tagA);
      start = r.recordingStartedAt;
      f.now = start.add(const Duration(hours: 1));
      final db = factory.database!;
      await db.execute('CREATE TABLE route_pressure (payload BLOB)');
      await db.execute(
        '''CREATE TRIGGER exhaust_route AFTER INSERT ON route_points
      BEGIN INSERT INTO route_pressure VALUES(zeroblob(1048576)); END''',
      );
      final pages =
          (await db.rawQuery('PRAGMA page_count')).single.values.first as int;
      await db.rawQuery('PRAGMA max_page_count = $pages');
      await expectLater(
        ingest([sample('retry-full', start)]),
        throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
      );
      expect((await current()).pointCount, 0);
      expect((await current()).routeRevision, 0);
      expect(await db.query('route_points'), isEmpty);
      expect(await db.query('route_pressure'), isEmpty);
      await db.execute('DROP TRIGGER exhaust_route');
      await db.rawQuery('PRAGMA max_page_count = 1073741823');
      await ingest([sample('retry-full', start)]);
      expect((await current()).pointCount, 1);
      expect((await current()).routeRevision, 1);
    },
  );
}

final class _CapacityFactory implements DatabaseFactory {
  Database? database;
  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async => database = await databaseFactoryFfiNoIsolate.openDatabase(
    path,
    options: options,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
