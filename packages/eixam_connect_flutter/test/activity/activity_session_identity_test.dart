import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/activity_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'activity_test_support.dart';

void main() {
  late MemoryActivityStore store;
  late ActivitySessionController controller;
  setUp(() async {
    store = MemoryActivityStore();
    controller = ActivitySessionController(store: store);
    await bind(controller, userA);
  });
  tearDown(() => controller.dispose());

  test(
    'disposed observers cannot replay data after a replacement SDK binds B',
    () async {
      final values = <SdkActivitySession?>[];
      final sub = controller.watchActiveActivitySession().listen(values.add);
      await pumpEventQueue();
      sub.pause();
      await controller.startActivitySession(activityKey: 'ski');
      await controller.dispose();
      controller = ActivitySessionController(store: store);
      await bind(controller, userB);
      expect(await controller.getActiveActivitySession(), isNull);
      sub.resume();
      await pumpEventQueue();
      expect(values, [null]);
      await sub.cancel();
    },
  );

  test(
    'paused initial restoration errors stay with the original principal',
    () async {
      await controller.startActivitySession(activityKey: 'ski');
      await controller.dispose();
      controller = ActivitySessionController(store: store);
      await bind(controller, userA);
      final gate = Completer<void>();
      store.nextRead = gate;
      final values = <SdkActivitySession?>[];
      final errors = <Object>[];
      final sub = controller.watchActiveActivitySession().listen(
        values.add,
        onError: errors.add,
      );
      sub.pause();
      await pumpEventQueue();
      final binding = bind(controller, userB, restore: false);
      gate.complete();
      await binding;
      sub.resume();
      await pumpEventQueue();
      expect(values, isEmpty);
      expect(errors, isEmpty);
      await sub.cancel();
    },
  );

  test('late A end cannot emit a null transition as B state', () async {
    final a = await controller.startActivitySession(activityKey: 'ski');
    final values = <SdkActivitySession?>[];
    final sub = controller.watchActiveActivitySession().listen(values.add);
    await pumpEventQueue();
    final gate = Completer<void>();
    store.nextWrite = gate;
    final rejected = expectLater(
      controller.endActivitySession(sessionId: a.sessionId),
      throwsA(activityError('E_ACTIVITY_UNAVAILABLE')),
    );
    await pumpEventQueue();
    final binding = bind(controller, userB, restore: false);
    final starting = controller.startActivitySession(activityKey: 'hunting');
    gate.complete();
    await rejected;
    await binding;
    final b = await starting;
    await pumpEventQueue();
    expect(values.map((s) => s?.sessionId).toList(), [
      a.sessionId,
      null,
      b.sessionId,
    ]);
    await sub.cancel();
  });

  test(
    'UTC logical start survives same-key retries and a new process clock',
    () async {
      await controller.dispose();
      var now = DateTime(2026, 10, 18, 9, 10, 11, 123, 456);
      final expected = now.toUtc();
      controller = ActivitySessionController(store: store, clock: () => now);
      await bind(controller, userA);
      final a = await controller.startActivitySession(activityKey: 'ski');
      expect(a.startedAt, expected);
      expect(a.startedAt.isUtc, isTrue);
      now = now.add(const Duration(days: 1));
      final retry = await controller.startActivitySession(activityKey: 'ski');
      expect(retry.startedAt, expected);
      await controller.dispose();
      controller = ActivitySessionController(store: store, clock: () => now);
      await bind(controller, userA);
      final restored = await controller.getActiveActivitySession();
      expect(restored?.sessionId, a.sessionId);
      expect(restored?.startedAt, expected);
      expect(restored?.startedAt.isUtc, isTrue);
    },
  );

  test('paused observers discard previous-principal cleanup errors', () async {
    await controller.startActivitySession(activityKey: 'ski');
    final values = <SdkActivitySession?>[];
    final errors = <Object>[];
    final sub = controller.watchActiveActivitySession().listen(
      values.add,
      onError: errors.add,
    );
    await pumpEventQueue();
    sub.pause();
    store.rejectRemove = true;
    await expectLater(
      bind(controller, userA, clear: true),
      throwsA(activityError('E_ACTIVITY_PERSISTENCE_FAILED')),
    );
    store.rejectRemove = false;
    await bind(controller, userB, restore: false);
    sub.resume();
    await pumpEventQueue();
    expect(errors, isEmpty);
    expect(values.last, isNull);
    await sub.cancel();
  });

  test(
    'failed cleanup emits an error, not a false confirmed null transition',
    () async {
      final a = await controller.startActivitySession(activityKey: 'ski');
      final values = <SdkActivitySession?>[];
      final errors = <Object>[];
      final sub = controller.watchActiveActivitySession().listen(
        values.add,
        onError: errors.add,
      );
      await pumpEventQueue();
      store.rejectRemove = true;
      await expectLater(
        bind(controller, userB, restore: false),
        throwsA(activityError('E_ACTIVITY_PERSISTENCE_FAILED')),
      );
      await pumpEventQueue();
      expect(values.map((s) => s?.sessionId).toList(), [a.sessionId]);
      expect(errors.single, activityError('E_ACTIVITY_PERSISTENCE_FAILED'));
      store.rejectRemove = false;
      expect(await controller.getActiveActivitySession(), isNull);
      await pumpEventQueue();
      expect(values.map((s) => s?.sessionId).toList(), [a.sessionId, null]);
      await sub.cancel();
    },
  );

  test(
    'blank optional canonical IDs remain absent and roundtrip safely',
    () async {
      await bind(controller, userA.copyWith(sdkUserId: ''), restore: false);
      final session = await controller.startActivitySession(activityKey: 'ski');
      await controller.dispose();
      controller = ActivitySessionController(store: store);
      await bind(controller, userA.copyWith(sdkUserId: 'canonical-a'));
      expect(
        (await controller.getActiveActivitySession())?.sessionId,
        session.sessionId,
      );
    },
  );

  test(
    'obsolete binding clears observers even when the latest identity action fails',
    () async {
      await controller.startActivitySession(activityKey: 'ski');
      final values = <SdkActivitySession?>[];
      final sub = controller.watchActiveActivitySession().listen(values.add);
      await pumpEventQueue();
      final gate = Completer<void>();
      final obsolete = expectLater(
        controller.withIdentityChange<void>(
          () => gate.future,
          currentSession: () => userB,
          backend: () => 'https://sdk.test',
        ),
        throwsA(activityError('E_ACTIVITY_UNAVAILABLE')),
      );
      await pumpEventQueue();
      final failure = StateError('latest identity failed');
      final latest = expectLater(
        controller.withIdentityChange<void>(
          () async => throw failure,
          currentSession: () => userB,
          backend: () => 'https://sdk.test',
        ),
        throwsA(same(failure)),
      );
      gate.complete();
      await obsolete;
      await latest;
      await pumpEventQueue();
      expect(values.last, isNull);
      await sub.cancel();
    },
  );

  test(
    'paused initial null is replaced with current null across account changes',
    () async {
      final values = <SdkActivitySession?>[];
      final sub = controller.watchActiveActivitySession().listen(values.add);
      sub.pause();
      await controller.getActiveActivitySession();
      await bind(controller, userB, restore: false);
      sub.resume();
      await pumpEventQueue();
      expect(values, [null]);
      await sub.cancel();
    },
  );

  test(
    'paused observers cannot replay A events after B becomes current',
    () async {
      final values = <SdkActivitySession?>[];
      final sub = controller.watchActiveActivitySession().listen(values.add);
      await pumpEventQueue();
      sub.pause();
      await controller.startActivitySession(activityKey: 'ski');
      await bind(controller, userB, restore: false);
      final b = await controller.startActivitySession(activityKey: 'hunting');
      sub.resume();
      await pumpEventQueue();
      expect(values.map((s) => s?.sessionId).toList(), [
        null,
        null,
        b.sessionId,
      ]);
      await sub.cancel();
    },
  );

  test(
    'logout clears disk and observer; unauthenticated commands use AuthException',
    () async {
      final a = await controller.startActivitySession(activityKey: 'ski');
      final values = <SdkActivitySession?>[];
      final sub = controller.watchActiveActivitySession().listen(values.add);
      await pumpEventQueue();
      await bind(controller, null, clear: true);
      await pumpEventQueue();
      expect(store.raw, isNull);
      expect(values.map((s) => s?.sessionId).toList(), [a.sessionId, null]);
      await expectLater(
        controller.startActivitySession(activityKey: 'ski'),
        throwsA(isA<AuthException>()),
      );
      await expectLater(
        controller.endActivitySession(sessionId: a.sessionId),
        throwsA(isA<AuthException>()),
      );
      await sub.cancel();
    },
  );

  test('A to B never exposes A; switching back does not resurrect A', () async {
    final a = await controller.startActivitySession(activityKey: 'ski');
    final values = <SdkActivitySession?>[];
    final sub = controller.watchActiveActivitySession().listen(values.add);
    await pumpEventQueue();
    await bind(controller, userB, restore: false);
    expect(await controller.getActiveActivitySession(), isNull);
    final b = await controller.startActivitySession(activityKey: 'hunting');
    await pumpEventQueue();
    expect(values.map((s) => s?.sessionId).toList(), [
      a.sessionId,
      null,
      b.sessionId,
    ]);
    await bind(controller, userA, restore: false);
    expect(await controller.getActiveActivitySession(), isNull);
    await sub.cancel();
  });

  test(
    'fresh runtime matching identity restores active, seed, and ended tombstone',
    () async {
      final a = await controller.startActivitySession(activityKey: 'ski');
      await controller.dispose();
      controller = ActivitySessionController(store: store);
      await bind(controller, userA);
      expect(
        (await controller.watchActiveActivitySession().first)?.sessionId,
        a.sessionId,
      );
      await controller.endActivitySession(sessionId: a.sessionId);
      final tombstone = store.raw;
      await controller.dispose();
      controller = ActivitySessionController(store: store);
      await bind(controller, userA);
      expect(await controller.getActiveActivitySession(), isNull);
      await controller.endActivitySession(sessionId: a.sessionId);
      expect(store.raw, tombstone);
      final next = await controller.startActivitySession(activityKey: 'ski');
      expect(next.sessionId, isNot(a.sessionId));
    },
  );

  test('different restored account and backend cannot adopt A', () async {
    await controller.startActivitySession(activityKey: 'ski');
    final aRaw = store.raw;
    for (final differentBackend in [false, true]) {
      await controller.dispose();
      store.raw = aRaw;
      controller = ActivitySessionController(store: store);
      await bind(
        controller,
        differentBackend ? userA : userB,
        backend: differentBackend ? 'https://other.test' : 'https://sdk.test',
      );
      expect(await controller.getActiveActivitySession(), isNull);
      expect(store.raw, isNull);
    }
  });

  test(
    'canonical enrichment and signing-key rotation preserve logical identity',
    () async {
      final a = await controller.startActivitySession(activityKey: 'ski');
      final enriched = userA.copyWith(
        sdkUserId: 'canonical-a',
        canonicalExternalUserId: 'canonical-external',
        userHash: 'rotated',
      );
      await bind(controller, enriched, restore: false);
      expect(
        (await controller.getActiveActivitySession())?.sessionId,
        a.sessionId,
      );
      await bind(
        controller,
        enriched.copyWith(sdkUserId: 'different-user'),
        restore: false,
      );
      expect(await controller.getActiveActivitySession(), isNull);
    },
  );

  test('orphan record is cleared before a fresh login', () async {
    await controller.startActivitySession(activityKey: 'ski');
    await controller.dispose();
    controller = ActivitySessionController(store: store);
    await bind(controller, null);
    expect(store.raw, isNull);
    await bind(controller, userA, restore: false);
    expect(await controller.getActiveActivitySession(), isNull);
  });

  test('cleanup failure blocks B until verified cleanup succeeds', () async {
    await controller.startActivitySession(activityKey: 'ski');
    store.rejectRemove = true;
    await expectLater(
      bind(controller, userB, restore: false),
      throwsA(activityError('E_ACTIVITY_PERSISTENCE_FAILED')),
    );
    await expectLater(
      controller.startActivitySession(activityKey: 'hunting'),
      throwsA(activityError('E_ACTIVITY_PERSISTENCE_FAILED')),
    );
    store.rejectRemove = false;
    expect(await controller.getActiveActivitySession(), isNull);
    expect(
      (await controller.startActivitySession(
        activityKey: 'hunting',
      )).activityKey,
      'hunting',
    );
  });

  test('in-flight A write is fenced before B binds and clears it', () async {
    await controller.getActiveActivitySession();
    final gate = Completer<void>();
    store.nextWrite = gate;
    final rejected = expectLater(
      controller.startActivitySession(activityKey: 'ski'),
      throwsA(activityError('E_ACTIVITY_UNAVAILABLE')),
    );
    await pumpEventQueue();
    final switchUser = bind(controller, userB, restore: false);
    gate.complete();
    await rejected;
    await switchUser;
    expect(await controller.getActiveActivitySession(), isNull);
    expect(store.raw, isNull);
  });

  test(
    'in-flight A restoration cannot emit A after a B switch begins',
    () async {
      await controller.startActivitySession(activityKey: 'ski');
      await controller.dispose();
      controller = ActivitySessionController(store: store);
      await bind(controller, userA);
      final gate = Completer<void>();
      store.nextRead = gate;
      final values = <SdkActivitySession?>[];
      final errors = <Object>[];
      final sub = controller.watchActiveActivitySession().listen(
        values.add,
        onError: errors.add,
      );
      await pumpEventQueue();
      final switchUser = bind(controller, userB, restore: false);
      gate.complete();
      await switchUser;
      await pumpEventQueue();
      expect(values, isEmpty);
      expect(errors.single, activityError('E_ACTIVITY_UNAVAILABLE'));
      expect(await controller.getActiveActivitySession(), isNull);
      await sub.cancel();
    },
  );

  test(
    'identity action failure is preserved and does not poison future commands',
    () async {
      final a = await controller.startActivitySession(activityKey: 'ski');
      final failure = StateError('identity fetch failed');
      await expectLater(
        controller.withIdentityChange<void>(
          () async => throw failure,
          currentSession: () => userA,
          backend: () => 'https://sdk.test',
        ),
        throwsA(same(failure)),
      );
      expect(
        (await controller.getActiveActivitySession())?.sessionId,
        a.sessionId,
      );
    },
  );

  test(
    'overlapping identity actions reject obsolete callers and expose last binding',
    () async {
      final gate = Completer<void>();
      final rejected = expectLater(
        controller.withIdentityChange<void>(
          () => gate.future,
          currentSession: () => userA,
          backend: () => 'https://sdk.test',
        ),
        throwsA(activityError('E_ACTIVITY_UNAVAILABLE')),
      );
      await pumpEventQueue();
      final switchUser = bind(controller, userB, restore: false);
      final start = controller.startActivitySession(activityKey: 'hunting');
      gate.complete();
      await rejected;
      await switchUser;
      expect((await start).activityKey, 'hunting');
    },
  );
}
