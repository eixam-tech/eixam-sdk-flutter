import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'recording_test_support.dart';

void main() {
  late RecordingFixture f;
  setUp(() async {
    f = await RecordingFixture.create();
  });
  tearDown(() async {
    await f.delete();
  });

  test('start persists independent secure ID and honest empty state', () async {
    final session = await f.logicalStart();
    final r = await f.controller.startActivityRecording(
      activitySession: session,
    );
    expect(r.recordingId, matches(r'^[a-f0-9]{32}$'));
    expect(r.recordingId, isNot(session.sessionId));
    expect(r.activitySessionId, session.sessionId);
    expect(r.activityKey, session.activityKey);
    expect(r.recordingStartedAt, f.now);
    expect(r.phase, ActivityRecordingPhase.active);
    expect(r.inputState, ActivityRecordingInputState.unbound);
    expect(r.deviceIdentity, isNull);
    expect(r.pointCount, 0);
    expect(r.segmentCount, 0);
    expect(r.recordedDistanceMeters, isNull);
    expect(r.routeQuality, ActivityRecordingRouteQuality.unknown);
    expect(r.recoveryState, ActivityRecordingRecoveryState.idle);
    expect(
      (await f.sessions.getActiveActivitySession())?.sessionId,
      session.sessionId,
    );
    expect(
      (await f.controller.getActivityRecording(
        recordingId: r.recordingId,
      ))?.recordingId,
      r.recordingId,
    );
  });

  test(
    'same start is idempotent and preserves original acceptance time',
    () async {
      final first = await f.start();
      f.now = f.now.add(const Duration(hours: 1));
      final retry = await f.start();
      expect(retry.recordingId, first.recordingId);
      expect(retry.recordingStartedAt, first.recordingStartedAt);
      expect(f.store.committedWrites, 1);
    },
  );

  test(
    'a different current session conflicts without replacing recording',
    () async {
      final first = await f.start();
      await f.sessions.endActivitySession(sessionId: first.activitySessionId);
      await expectLater(
        f.start(),
        throwsA(recordingError('E_RECORDING_CONFLICT')),
      );
      expect(
        (await f.controller.getActivityRecording(
          recordingId: first.recordingId,
        ))?.phase,
        ActivityRecordingPhase.active,
      );
    },
  );

  for (final mismatch in ['id', 'key', 'time']) {
    test('start rejects exact session tuple mismatch: $mismatch', () async {
      final s = await f.logicalStart();
      final wrong = SdkActivitySession(
        sessionId: mismatch == 'id' ? 'wrong' : s.sessionId,
        activityKey: mismatch == 'key' ? 'other' : s.activityKey,
        startedAt: mismatch == 'time'
            ? s.startedAt.add(const Duration(seconds: 1))
            : s.startedAt,
      );
      await expectLater(
        f.controller.startActivityRecording(activitySession: wrong),
        throwsA(recordingError('E_RECORDING_SESSION_MISMATCH')),
      );
      expect(await f.controller.getActiveActivityRecording(), isNull);
    });
  }

  test('missing identity cannot start or look up recording IDs', () async {
    final s = await f.logicalStart();
    await f.bind(null, clear: true);
    await expectLater(
      f.controller.startActivityRecording(activitySession: s),
      throwsA(recordingError('E_RECORDING_IDENTITY_REQUIRED')),
    );
    await expectLater(
      f.controller.getActivityRecording(recordingId: 'unknown'),
      throwsA(recordingError('E_RECORDING_IDENTITY_REQUIRED')),
    );
    expect(await f.controller.getActiveActivityRecording(), isNull);
  });

  for (final connected in [false, true]) {
    test(
      'verified binding can start without claiming observation: $connected',
      () async {
        f.connected = connected;
        final r = await f.start(device: tagA.toLowerCase());
        expect(r.deviceIdentity, tagA);
        expect(
          r.inputState,
          connected
              ? ActivityRecordingInputState.unavailable
              : ActivityRecordingInputState.disconnected,
        );
        expect(r.recordedDistanceMeters, isNull);
      },
    );
  }

  test(
    'unverified device and display-name selection fail without recording',
    () async {
      f.verified.clear();
      for (final requested in [tagA, 'my TAG', 'first-device']) {
        await expectLater(
          f.start(device: requested),
          throwsA(recordingError('E_RECORDING_DEVICE_MISMATCH')),
        );
      }
      expect(await f.controller.getActiveActivityRecording(), isNull);
    },
  );

  test(
    'explicit binding is immutable and same-binding retry needs no reconnect',
    () async {
      final r = await f.start();
      final bound = await f.controller.bindActivityRecordingDevice(
        recordingId: r.recordingId,
        deviceIdentity: tagA,
      );
      expect(bound.deviceIdentity, tagA);
      f.verified.clear();
      final retry = await f.controller.bindActivityRecordingDevice(
        recordingId: r.recordingId,
        deviceIdentity: tagA.toLowerCase(),
      );
      expect(retry.deviceIdentity, tagA);
      await expectLater(
        f.controller.bindActivityRecordingDevice(
          recordingId: r.recordingId,
          deviceIdentity: tagB,
        ),
        throwsA(recordingError('E_RECORDING_DEVICE_MISMATCH')),
      );
      await f.controller.finishActivityRecording(recordingId: r.recordingId);
      await expectLater(
        f.controller.bindActivityRecordingDevice(
          recordingId: r.recordingId,
          deviceIdentity: tagA,
        ),
        throwsA(recordingError('E_RECORDING_CONFLICT')),
      );
    },
  );

  test(
    'finish has two committed phases and does not end logical session',
    () async {
      final r = await f.start();
      final seen = <SdkActivityRecording?>[];
      final sub = f.controller.watchActiveActivityRecording().listen(seen.add);
      await pumpEventQueue();
      f.now = f.now.add(const Duration(minutes: 2));
      final result = await f.controller.finishActivityRecording(
        recordingId: r.recordingId,
      );
      await pumpEventQueue();
      expect(result.endedAt, f.now);
      expect(result.phase, ActivityRecordingPhase.finished);
      expect(seen.map((v) => v?.phase), [
        ActivityRecordingPhase.active,
        ActivityRecordingPhase.finalizing,
        null,
      ]);
      expect(await f.controller.getActiveActivityRecording(), isNull);
      expect(
        (await f.sessions.getActiveActivitySession())?.sessionId,
        r.activitySessionId,
      );
      expect(result.recordedDistanceMeters, isNull);
      expect(result.routeRevision, 0);
      expect(result.previousRouteRevision, 0);
      expect(result.routeChangedFrom, isNull);
      await sub.cancel();
    },
  );

  test('explicit finish UTC cutoff is fixed across retries', () async {
    final r = await f.start();
    f.now = f.now.add(const Duration(minutes: 5));
    final cutoff = f.now.subtract(const Duration(minutes: 1)).toLocal();
    final result = await f.controller.finishActivityRecording(
      recordingId: r.recordingId,
      endedAt: cutoff,
    );
    expect(result.endedAt, cutoff.toUtc());
    expect(result.endedAt!.isUtc, isTrue);
    f.now = f.now.add(const Duration(hours: 1));
    final retry = await f.controller.finishActivityRecording(
      recordingId: r.recordingId,
      endedAt: f.now,
    );
    expect(retry.endedAt, result.endedAt);
  });

  test(
    'invalid and future cutoff fail without changing active recording',
    () async {
      final r = await f.start();
      for (final cutoff in [
        r.recordingStartedAt.subtract(const Duration(microseconds: 1)),
        f.now.add(const Duration(seconds: 1)),
      ]) {
        await expectLater(
          f.controller.finishActivityRecording(
            recordingId: r.recordingId,
            endedAt: cutoff,
          ),
          throwsA(recordingError('E_RECORDING_INVALID_TIME')),
        );
      }
      expect(
        (await f.controller.getActiveActivityRecording())?.endedAt,
        isNull,
      );
    },
  );

  test(
    'unknown lookup is null and unknown finish is typed not-found',
    () async {
      expect(
        await f.controller.getActivityRecording(recordingId: 'unknown'),
        isNull,
      );
      await expectLater(
        f.controller.finishActivityRecording(recordingId: 'unknown'),
        throwsA(recordingError('E_RECORDING_NOT_FOUND')),
      );
    },
  );

  test('finishing retained A cannot finish a different active B', () async {
    final a = await f.start();
    final endA = await f.controller.finishActivityRecording(
      recordingId: a.recordingId,
    );
    await f.sessions.endActivitySession(sessionId: a.activitySessionId);
    final b = await f.start();
    final retry = await f.controller.finishActivityRecording(
      recordingId: a.recordingId,
    );
    expect(retry.endedAt, endA.endedAt);
    expect(
      (await f.controller.getActiveActivityRecording())?.recordingId,
      b.recordingId,
    );
  });

  test('finished association cannot silently restart', () async {
    final r = await f.start();
    await f.controller.finishActivityRecording(recordingId: r.recordingId);
    await expectLater(
      f.start(),
      throwsA(recordingError('E_RECORDING_ALREADY_FINISHED')),
    );
  });

  for (final finished in [false, true]) {
    test(
      'empty route is honest, terminal and revision-consistent: $finished',
      () async {
        final r = await f.start();
        if (finished) {
          await f.controller.finishActivityRecording(
            recordingId: r.recordingId,
          );
        }
        final pages = await f.controller
            .readActivityRecordingRoute(
              recordingId: r.recordingId,
              fromInclusive: f.now,
              expectedRouteRevision: 0,
              pageSize: 1,
            )
            .toList();
        expect(pages, hasLength(1));
        expect(pages.single.recordingId, r.recordingId);
        expect(pages.single.routeRevision, 0);
        expect(pages.single.segments, isEmpty);
        expect(pages.single.gaps, isEmpty);
        expect(pages.single.isLast, isTrue);
        await expectLater(
          f.controller
              .readActivityRecordingRoute(
                recordingId: r.recordingId,
                expectedRouteRevision: 1,
              )
              .toList(),
          throwsA(recordingError('E_RECORDING_ROUTE_REVISION_CHANGED')),
        );
      },
    );
  }

  test(
    'route reader rejects invalid page size and missing recording',
    () async {
      final r = await f.start();
      await expectLater(
        f.controller
            .readActivityRecordingRoute(recordingId: r.recordingId, pageSize: 0)
            .toList(),
        throwsArgumentError,
      );
      await expectLater(
        f.controller
            .readActivityRecordingRoute(recordingId: 'missing')
            .toList(),
        throwsA(recordingError('E_RECORDING_NOT_FOUND')),
      );
    },
  );

  test(
    'history recovery explicitly unavailable with unchanged idle/unknown facts',
    () async {
      final r = await f.start();
      await expectLater(
        f.controller.recoverActivityRecordingHistory(
          recordingId: r.recordingId,
        ),
        throwsA(recordingError('E_RECORDING_UNAVAILABLE')),
      );
      final after = await f.controller.getActiveActivityRecording();
      expect(after?.recoveryState, ActivityRecordingRecoveryState.idle);
      expect(after?.routeQuality, ActivityRecordingRouteQuality.unknown);
    },
  );

  test('watch seed/start/bind and cancellation do not deadlock', () async {
    final seen = <SdkActivityRecording?>[];
    final sub = f.controller.watchActiveActivityRecording().listen(seen.add);
    await pumpEventQueue();
    final r = await f.start();
    await f.controller.bindActivityRecordingDevice(
      recordingId: r.recordingId,
      deviceIdentity: tagA,
    );
    await pumpEventQueue();
    expect(seen.map((r) => r?.deviceIdentity), [null, null, tagA]);
    expect(seen[1]?.recordingId, r.recordingId);
    await sub.cancel().timeout(const Duration(seconds: 1));
    final length = seen.length;
    await f.controller.finishActivityRecording(recordingId: r.recordingId);
    await pumpEventQueue();
    expect(seen, hasLength(length));
    await f.controller.watchActiveActivityRecording().first.timeout(
      const Duration(seconds: 1),
    );
  });

  test(
    'commit precedes publication and rollback preserves observer state',
    () async {
      final seen = <SdkActivityRecording?>[];
      final sub = f.controller.watchActiveActivityRecording().listen(seen.add);
      await pumpEventQueue();
      final gate = f.store.writeGate = Completer<void>();
      final entered = f.store.writeEntered = Completer<void>();
      final start = f.start();
      await entered.future;
      expect(seen, [null]);
      gate.complete();
      final r = await start;
      await pumpEventQueue();
      expect(seen.last?.recordingId, r.recordingId);
      f.store.failNextWrite = true;
      await expectLater(
        f.controller.bindActivityRecordingDevice(
          recordingId: r.recordingId,
          deviceIdentity: tagA,
        ),
        throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
      );
      await pumpEventQueue();
      expect(seen.last?.deviceIdentity, isNull);
      expect(
        (await f.controller.getActiveActivityRecording())?.deviceIdentity,
        isNull,
      );
      await sub.cancel();
    },
  );

  test('failed start rollback creates no recording', () async {
    await f.controller.getActiveActivityRecording();
    f.store.failNextWrite = true;
    await expectLater(
      f.start(),
      throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
    );
    expect(await f.controller.getActiveActivityRecording(), isNull);
  });

  test(
    'orphan or unreadable session preserves facts and permits explicit finish',
    () async {
      final r = await f.start();
      await f.sessions.endActivitySession(sessionId: r.activitySessionId);
      await expectLater(
        f.controller.getActiveActivityRecording(),
        throwsA(recordingError('E_RECORDING_SESSION_MISMATCH')),
      );
      expect(
        (await f.controller.getActivityRecording(
          recordingId: r.recordingId,
        ))?.phase,
        ActivityRecordingPhase.active,
      );
      await expectLater(
        f.controller.bindActivityRecordingDevice(
          recordingId: r.recordingId,
          deviceIdentity: tagA,
        ),
        throwsA(recordingError('E_RECORDING_SESSION_MISMATCH')),
      );
      final finished = await f.controller.finishActivityRecording(
        recordingId: r.recordingId,
      );
      expect(finished.phase, ActivityRecordingPhase.finished);
    },
  );

  test(
    'ordinary disposal is idempotent, closes observation and fences commands',
    () async {
      await f.start();
      final done = Completer<void>();
      final sub = f.controller.watchActiveActivityRecording().listen(
        (_) {},
        onDone: done.complete,
      );
      await pumpEventQueue();
      await f.dispose();
      await f.dispose();
      await done.future.timeout(const Duration(seconds: 1));
      await sub.cancel();
      await expectLater(
        f.controller.getActiveActivityRecording(),
        throwsA(recordingError('E_RECORDING_UNAVAILABLE')),
      );
    },
  );
}
