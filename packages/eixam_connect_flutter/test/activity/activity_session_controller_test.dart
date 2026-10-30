import 'dart:async';
import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/activity_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'activity_test_support.dart';

void main() {
  late MemoryActivityStore store;
  late ActivitySessionController controller;
  setUp(() async {
    store = MemoryActivityStore();
    controller = ActivitySessionController(
      store: store,
      clock: () => DateTime.utc(2026),
    );
    await bind(controller, userA);
  });
  tearDown(() => controller.dispose());

  test(
    'seeds null; publishes start then null; retries do not duplicate events',
    () async {
      final values = <SdkActivitySession?>[];
      final sub = controller.watchActiveActivitySession().listen(values.add);
      await pumpEventQueue();
      expect(values, [null]);
      final a = await controller.startActivitySession(
        activityKey: 'org.example.paddling',
      );
      final same = await controller.startActivitySession(
        activityKey: a.activityKey,
      );
      expect(same.sessionId, a.sessionId);
      expect(store.writes, 1);
      await controller.endActivitySession(sessionId: a.sessionId);
      await controller.endActivitySession(sessionId: a.sessionId);
      await pumpEventQueue();
      expect(values.map((s) => s?.sessionId).toList(), [
        null,
        a.sessionId,
        null,
      ]);
      expect(jsonDecode(store.raw!)['state'], 'ended');
      expect(store.writes, 2);
      final next = await controller.startActivitySession(
        activityKey: a.activityKey,
      );
      expect(next.sessionId, isNot(a.sessionId));
      await sub.cancel();
    },
  );

  test(
    'different active key and wrong current/tombstone IDs conflict',
    () async {
      final a = await controller.startActivitySession(activityKey: 'mountain');
      final raw = store.raw;
      await expectLater(
        controller.startActivitySession(activityKey: 'ski'),
        throwsA(activityError('E_ACTIVITY_CONFLICT')),
      );
      await expectLater(
        controller.endActivitySession(sessionId: 'wrong'),
        throwsA(activityError('E_ACTIVITY_CONFLICT')),
      );
      expect(store.raw, raw);
      await controller.endActivitySession(sessionId: a.sessionId);
      await expectLater(
        controller.endActivitySession(sessionId: 'wrong'),
        throwsA(activityError('E_ACTIVITY_CONFLICT')),
      );
    },
  );

  test('end without any stored record is a no-op', () async {
    await controller.endActivitySession(sessionId: 'missing');
    expect(store.writes, 0);
    expect(await controller.getActiveActivitySession(), isNull);
  });

  test('invalid keys fail without writing', () async {
    await expectLater(
      controller.startActivitySession(activityKey: 'Ski'),
      throwsA(activityError('E_ACTIVITY_INVALID_KEY')),
    );
    expect(store.raw, isNull);
  });

  test('same-key concurrent starts share one ID and one write', () async {
    final sessions = await Future.wait(
      List.generate(
        10,
        (_) => controller.startActivitySession(activityKey: 'ski'),
      ),
    );
    expect(sessions.map((s) => s.sessionId).toSet(), hasLength(1));
    expect(store.writes, 1);
  });

  test(
    'different-key starts choose queue order; failure does not poison queue',
    () async {
      final first = controller.startActivitySession(activityKey: 'mountain');
      final second = controller.startActivitySession(activityKey: 'ski');
      final rejected = expectLater(
        second,
        throwsA(activityError('E_ACTIVITY_CONFLICT')),
      );
      final a = await first;
      await rejected;
      expect(
        (await controller.getActiveActivitySession())?.sessionId,
        a.sessionId,
      );
      await controller.endActivitySession(sessionId: a.sessionId);
      expect(
        (await controller.startActivitySession(activityKey: 'ski')).activityKey,
        'ski',
      );
    },
  );

  test(
    'same-key start followed immediately by matching end is ordered',
    () async {
      final a = await controller.startActivitySession(activityKey: 'ski');
      final start = controller.startActivitySession(activityKey: 'ski');
      final end = controller.endActivitySession(sessionId: a.sessionId);
      expect((await start).sessionId, a.sessionId);
      await end;
      expect(await controller.getActiveActivitySession(), isNull);
    },
  );

  test(
    'restoration racing start cannot replace a restored different activity',
    () async {
      final a = await controller.startActivitySession(activityKey: 'ski');
      await controller.dispose();
      controller = ActivitySessionController(store: store);
      await bind(controller, userA);
      final gate = Completer<void>();
      store.nextRead = gate;
      final restoring = controller.getActiveActivitySession();
      final rejected = expectLater(
        controller.startActivitySession(activityKey: 'mountain'),
        throwsA(activityError('E_ACTIVITY_CONFLICT')),
      );
      await pumpEventQueue();
      gate.complete();
      expect((await restoring)?.sessionId, a.sessionId);
      await rejected;
    },
  );

  test(
    'subscribe during blocked restore receives seed and subsequent commit',
    () async {
      final gate = Completer<void>();
      store.nextRead = gate;
      final values = <SdkActivitySession?>[];
      final sub = controller.watchActiveActivitySession().listen(values.add);
      final start = controller.startActivitySession(activityKey: 'ski');
      await pumpEventQueue();
      expect(values, isEmpty);
      gate.complete();
      final a = await start;
      await pumpEventQueue();
      expect(values.map((s) => s?.sessionId).toList(), [null, a.sessionId]);
      await sub.cancel();
    },
  );

  test(
    'cancelling a subscription during restoration never registers it',
    () async {
      final gate = Completer<void>();
      store.nextRead = gate;
      final values = <SdkActivitySession?>[];
      final sub = controller.watchActiveActivitySession().listen(values.add);
      await pumpEventQueue();
      await sub.cancel();
      gate.complete();
      await controller.startActivitySession(activityKey: 'ski');
      expect(values, isEmpty);
    },
  );

  test(
    'rejected and thrown writes preserve prior state and allow retry',
    () async {
      for (final throws in [false, true]) {
        store.rejectWrites = !throws;
        store.throwWrites = throws;
        await expectLater(
          controller.startActivitySession(activityKey: 'ski'),
          throwsA(activityError('E_ACTIVITY_PERSISTENCE_FAILED')),
        );
        expect(await controller.getActiveActivitySession(), isNull);
      }
      store.rejectWrites = store.throwWrites = false;
      expect(
        (await controller.startActivitySession(activityKey: 'ski')).activityKey,
        'ski',
      );
    },
  );

  test(
    'applied writes with rejected/lost acknowledgements reconcile successfully',
    () async {
      for (final throws in [false, true]) {
        store.rejectWrites = !throws;
        store.throwWrites = throws;
        store.applyBeforeFailure = true;
        final a = await controller.startActivitySession(activityKey: 'ski');
        await controller.endActivitySession(sessionId: a.sessionId);
        expect(await controller.getActiveActivitySession(), isNull);
      }
    },
  );

  test(
    'unresolved write emits no success and blocks until readable reload',
    () async {
      final values = <SdkActivitySession?>[];
      final sub = controller.watchActiveActivitySession().listen(values.add);
      await pumpEventQueue();
      store.failReadAfterWrite = true;
      await expectLater(
        controller.startActivitySession(activityKey: 'ski'),
        throwsA(activityError('E_ACTIVITY_PERSISTENCE_FAILED')),
      );
      await expectLater(
        controller.getActiveActivitySession(),
        throwsA(activityError('E_ACTIVITY_RESTORE_FAILED')),
      );
      expect(values, [null]);
      store.unreadable = store.failReadAfterWrite = false;
      final restored = await controller.getActiveActivitySession();
      await pumpEventQueue();
      expect(values.map((s) => s?.sessionId).toList(), [
        null,
        restored!.sessionId,
      ]);
      expect(store.writes, 1);
      await sub.cancel();
    },
  );

  test(
    'failed end keeps active state until the tombstone is confirmed',
    () async {
      final a = await controller.startActivitySession(activityKey: 'ski');
      store.rejectWrites = true;
      await expectLater(
        controller.endActivitySession(sessionId: a.sessionId),
        throwsA(activityError('E_ACTIVITY_PERSISTENCE_FAILED')),
      );
      expect(
        (await controller.getActiveActivitySession())?.sessionId,
        a.sessionId,
      );
      store.rejectWrites = false;
      await controller.endActivitySession(sessionId: a.sessionId);
      expect(await controller.getActiveActivitySession(), isNull);
    },
  );

  test('dispose releases lease without ending persisted session', () async {
    final a = await controller.startActivitySession(activityKey: 'ski');
    final raw = store.raw;
    final other = ActivitySessionController(store: store);
    addTearDown(other.dispose);
    await bind(other, userA);
    await expectLater(
      other.getActiveActivitySession(),
      throwsA(activityError('E_ACTIVITY_UNAVAILABLE')),
    );
    await controller.dispose();
    expect(store.raw, raw);
    expect((await other.getActiveActivitySession())?.sessionId, a.sessionId);
    await expectLater(
      controller.getActiveActivitySession(),
      throwsA(activityError('E_ACTIVITY_UNAVAILABLE')),
    );
  });

  test(
    'contending runtime cleanup cannot erase the first writer record',
    () async {
      final a = await controller.startActivitySession(activityKey: 'ski');
      final other = ActivitySessionController(store: store);
      addTearDown(other.dispose);
      await bind(other, userB, restore: false);
      await bind(other, null, clear: true);
      expect(
        (await controller.getActiveActivitySession())?.sessionId,
        a.sessionId,
      );
      expect(jsonDecode(store.raw!)['state'], 'active');
    },
  );
}
