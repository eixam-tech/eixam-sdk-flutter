import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/activity_availability_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'availability_test_support.dart';

void main() {
  late MemoryStore store;
  late Remote remote;
  late ActivityAvailabilityController controller;
  setUp(() async {
    store = MemoryStore();
    remote = Remote();
    controller = ActivityAvailabilityController(store: store, remote: remote);
    await bind(controller, a);
  });
  tearDown(() => controller.dispose());

  for (final scope in ['user', 'app', 'backend', 'canonical']) {
    test(
      '$scope transition invalidates and never resurrects previous data',
      () async {
        final original = a.copyWith(sdkUserId: 'canonical-a');
        await bind(controller, original);
        await controller.refreshActivityAvailability();
        final next = switch (scope) {
          'user' => b,
          'app' => a.copyWith(appId: 'app-b'),
          'canonical' => a.copyWith(sdkUserId: 'canonical-b'),
          _ => original,
        };
        await bind(
          controller,
          next,
          restore: false,
          backend: scope == 'backend'
              ? 'https://other.test'
              : 'https://sdk.test',
        );
        expect(await controller.getCachedActivityAvailability(), isNull);
        expect(store.raw, isNull);
        await bind(controller, original, restore: false);
        expect(await controller.getCachedActivityAvailability(), isNull);
      },
    );

    test(
      '$scope cache separation also applies across runtime restoration',
      () async {
        await bind(controller, a.copyWith(sdkUserId: 'canonical-a'));
        await controller.refreshActivityAvailability();
        await controller.dispose();
        controller = ActivityAvailabilityController(
          store: store,
          remote: remote,
        );
        final next = switch (scope) {
          'user' => b,
          'app' => a.copyWith(appId: 'app-b'),
          'canonical' => a.copyWith(sdkUserId: 'canonical-b'),
          _ => a,
        };
        await bind(
          controller,
          next,
          backend: scope == 'backend'
              ? 'https://other.test'
              : 'https://sdk.test',
        );
        expect(await controller.getCachedActivityAvailability(), isNull);
        expect(store.raw, isNull);
      },
    );
  }

  test(
    'signing rotation/canonical enrichment/trailing backend slash preserve cache',
    () async {
      final first = await controller.refreshActivityAvailability();
      final rotated = a.copyWith(
        userHash: 'rotated',
        sdkUserId: 'canonical-a',
        canonicalExternalUserId: 'canonical-external',
      );
      await bind(
        controller,
        rotated,
        restore: false,
        backend: 'https://sdk.test///',
      );
      expect(
        (await controller.getCachedActivityAvailability())!.fetchedAt,
        first.fetchedAt,
      );
      await controller.refreshActivityAvailability();
      expect(remote.sessions.last.userHash, 'rotated');
    },
  );

  for (final outcome in ['success', 'network', '401']) {
    test('late A $outcome cannot affect B or block its refresh', () async {
      final gate = Completer<List<SdkAvailableActivity>>();
      remote.next = gate;
      final rejected = expectLater(
        controller.refreshActivityAvailability(),
        throwsA(availabilityError('UNAVAILABLE')),
      );
      await pumpEventQueue();
      await bind(controller, b, restore: false);
      remote.activities = [ski];
      await controller.refreshActivityAvailability();
      final bRaw = store.raw;
      if (outcome == 'success') {
        gate.complete([mountain]);
      } else {
        gate.completeError(
          outcome == '401'
              ? const AuthException('unauthorized', '401')
              : const NetworkException('offline', 'offline'),
        );
      }
      await rejected;
      expect(store.raw, bRaw);
      expect(
        (await controller.getCachedActivityAvailability())!
            .activities
            .single
            .key,
        ski.key,
      );
    });
  }

  test(
    'delayed A disk write is removed before B can restore or publish',
    () async {
      await controller.getCachedActivityAvailability();
      final gate = Completer<void>();
      store.nextWrite = gate;
      final rejected = expectLater(
        controller.refreshActivityAvailability(),
        throwsA(availabilityError('UNAVAILABLE')),
      );
      await pumpEventQueue();
      final binding = bind(controller, b, restore: false);
      final bRead = controller.getCachedActivityAvailability();
      gate.complete();
      await rejected;
      await binding;
      expect(await bRead, isNull);
      expect(store.raw, isNull);
    },
  );

  for (final operation in ['logout', 'wipe', 'dispose']) {
    test('$operation during refresh fences late publication/write', () async {
      await controller.refreshActivityAvailability();
      final oldRaw = store.raw;
      final gate = Completer<List<SdkAvailableActivity>>();
      remote.next = gate;
      final rejected = expectLater(
        controller.refreshActivityAvailability(),
        throwsA(availabilityError('UNAVAILABLE')),
      );
      await pumpEventQueue();
      if (operation == 'dispose') {
        await controller.dispose();
      } else {
        await bind(controller, operation == 'logout' ? null : a, clear: true);
      }
      gate.complete([ski]);
      await rejected;
      expect(store.raw, operation == 'dispose' ? oldRaw : null);
    });
  }

  test('dispose during disk write reconciles stale write away', () async {
    final gate = Completer<void>();
    store.nextWrite = gate;
    final rejected = expectLater(
      controller.refreshActivityAvailability(),
      throwsA(availabilityError('UNAVAILABLE')),
    );
    await pumpEventQueue();
    final disposing = controller.dispose();
    gate.complete();
    await disposing;
    await rejected;
    expect(store.raw, isNull);
  });

  test(
    'paused subscriber cannot replay A data/errors after B binding starts',
    () async {
      final values = <SdkActivityAvailability?>[];
      final errors = <Object>[];
      final sub = controller.watchActivityAvailability().listen(
        values.add,
        onError: errors.add,
      );
      await pumpEventQueue();
      sub.pause();
      await controller.refreshActivityAvailability();
      remote.error = const NetworkException('offline', 'offline');
      await expectLater(
        controller.refreshActivityAvailability(),
        throwsA(isA<NetworkException>()),
      );
      final action = Completer<void>();
      final binding = controller.withIdentityChange<void>(
        () => action.future,
        currentSession: () => b,
        backend: () => 'https://sdk.test',
      );
      sub.resume();
      await pumpEventQueue();
      expect(values, [null, null]);
      expect(errors, isEmpty);
      action.complete();
      await binding;
      await sub.cancel();
    },
  );

  test(
    'paused seed restoration errors remain fenced and observer recovers for B',
    () async {
      store.raw = 'corrupt';
      final errors = <Object>[];
      final values = <SdkActivityAvailability?>[];
      final sub = controller.watchActivityAvailability().listen(
        values.add,
        onError: errors.add,
      );
      sub.pause();
      await pumpEventQueue();
      await bind(controller, b, restore: false);
      sub.resume();
      await pumpEventQueue();
      expect(errors, isEmpty);
      expect(values, isNotEmpty);
      expect(values.every((v) => v == null), isTrue);
      await sub.cancel();
    },
  );

  test(
    'delayed restore cannot seed old identity; B watcher still receives refresh',
    () async {
      await controller.refreshActivityAvailability();
      await controller.dispose();
      controller = ActivityAvailabilityController(store: store, remote: remote);
      await bind(controller, a);
      final gate = Completer<void>();
      store.nextRead = gate;
      final values = <SdkActivityAvailability?>[];
      final errors = <Object>[];
      final sub = controller.watchActivityAvailability().listen(
        values.add,
        onError: errors.add,
      );
      await pumpEventQueue();
      final binding = bind(controller, b, restore: false);
      gate.complete();
      await binding;
      remote.activities = [ski];
      await controller.refreshActivityAvailability();
      await pumpEventQueue();
      expect(errors, isEmpty);
      expect(
        values
            .whereType<SdkActivityAvailability>()
            .single
            .activities
            .single
            .key,
        ski.key,
      );
      await sub.cancel();
    },
  );

  test(
    'cleanup failure blocks data access until checked deletion succeeds',
    () async {
      await controller.refreshActivityAvailability();
      store.rejectRemove = true;
      await expectLater(
        bind(controller, b, restore: false),
        throwsA(availabilityError('PERSISTENCE_FAILED')),
      );
      await expectLater(
        controller.getCachedActivityAvailability(),
        throwsA(availabilityError('PERSISTENCE_FAILED')),
      );
      store.rejectRemove = false;
      expect(await controller.getCachedActivityAvailability(), isNull);
    },
  );

  test(
    'failed identity action preserves original error and queue can recover',
    () async {
      await controller.refreshActivityAvailability();
      final failure = StateError('identity action failed');
      await expectLater(
        controller.withIdentityChange<void>(
          () async => throw failure,
          currentSession: () => a,
          backend: () => 'https://sdk.test',
        ),
        throwsA(same(failure)),
      );
      expect(
        (await controller.getCachedActivityAvailability())!
            .activities
            .single
            .key,
        mountain.key,
      );
      await bind(controller, b, restore: false);
      expect(await controller.getCachedActivityAvailability(), isNull);
    },
  );

  test(
    'overlapping bindings reject obsolete caller and expose latest identity',
    () async {
      final gate = Completer<void>();
      final rejected = expectLater(
        controller.withIdentityChange<void>(
          () => gate.future,
          currentSession: () => a,
          backend: () => 'https://sdk.test',
        ),
        throwsA(availabilityError('UNAVAILABLE')),
      );
      await pumpEventQueue();
      final binding = bind(controller, b, restore: false);
      final refresh = controller.refreshActivityAvailability();
      gate.complete();
      await rejected;
      await binding;
      await refresh;
      expect(remote.sessions.last.externalUserId, b.externalUserId);
    },
  );

  test(
    'logout without identity returns no cache and refresh requires auth',
    () async {
      await bind(controller, null, clear: true);
      expect(await controller.getCachedActivityAvailability(), isNull);
      await expectLater(
        controller.refreshActivityAvailability(),
        throwsA(isA<AuthException>()),
      );
      expect(remote.calls, 0);
    },
  );

  test(
    'late identity-cleanup error cannot cross a newer identity fence',
    () async {
      await controller.refreshActivityAvailability();
      final values = <SdkActivityAvailability?>[];
      final errors = <Object>[];
      final sub = controller.watchActivityAvailability().listen(
        values.add,
        onError: errors.add,
      );
      await pumpEventQueue();
      sub.pause();
      final gate = Completer<void>();
      store.nextRemove = gate;
      store.rejectRemove = true;
      final rejected = expectLater(
        bind(controller, b, restore: false),
        throwsA(availabilityError('PERSISTENCE_FAILED')),
      );
      await pumpEventQueue();
      final latest = expectLater(
        bind(controller, a, restore: false),
        throwsA(availabilityError('PERSISTENCE_FAILED')),
      );
      gate.complete();
      await rejected;
      await latest;
      // The latest identity legitimately receives its own cleanup error only.
      sub.resume();
      await pumpEventQueue();
      expect(errors, hasLength(1));
      expect(errors.single, availabilityError('PERSISTENCE_FAILED'));
      store.rejectRemove = false;
      expect(await controller.getCachedActivityAvailability(), isNull);
      await sub.cancel();
    },
  );

  test(
    '401 cleanup completing after a switch cannot emit old auth/error into B',
    () async {
      await controller.refreshActivityAvailability();
      final errors = <Object>[];
      final sub = controller.watchActivityAvailability().listen(
        (_) {},
        onError: errors.add,
      );
      await pumpEventQueue();
      final gate = Completer<void>();
      store.nextRemove = gate;
      remote.error = const AuthException('unauthorized', '401');
      final rejected = expectLater(
        controller.refreshActivityAvailability(),
        throwsA(availabilityError('UNAVAILABLE')),
      );
      await pumpEventQueue();
      final binding = bind(controller, b, restore: false);
      gate.complete();
      await rejected;
      await binding;
      await pumpEventQueue();
      expect(errors, isEmpty);
      expect(await controller.getCachedActivityAvailability(), isNull);
      await sub.cancel();
    },
  );

  test(
    'paused observer cannot replay A after disposal and replacement B runtime',
    () async {
      await controller.refreshActivityAvailability();
      final values = <SdkActivityAvailability?>[];
      final errors = <Object>[];
      final sub = controller.watchActivityAvailability().listen(
        values.add,
        onError: errors.add,
      );
      await pumpEventQueue();
      sub.pause();
      remote.activities = [ski];
      await controller.refreshActivityAvailability();
      await controller.dispose();
      controller = ActivityAvailabilityController(store: store, remote: remote);
      await bind(controller, b);
      sub.resume();
      await pumpEventQueue();
      expect(values, hasLength(1));
      expect(values.single!.activities.single.key, mountain.key);
      expect(errors, isEmpty);
      expect(await controller.getCachedActivityAvailability(), isNull);
      await sub.cancel();
    },
  );

  test('watch subscribed after disposal closes without data', () async {
    await controller.dispose();
    expect(await controller.watchActivityAvailability().toList(), isEmpty);
  });

  test(
    'disposal during watch restoration closes the unregistered observer',
    () async {
      final gate = Completer<void>();
      store.nextRead = gate;
      final events = controller.watchActivityAvailability().toList();
      await pumpEventQueue();
      final disposing = controller.dispose();
      gate.complete();
      await disposing;
      expect(await events, isEmpty);
    },
  );
}
