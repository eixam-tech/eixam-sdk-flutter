import 'dart:async';
import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_availability_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/sdk/activity_availability_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'availability_test_support.dart';

void main() {
  late MemoryStore store;
  late Remote remote;
  late ActivityAvailabilityController controller;
  setUp(() async {
    store = MemoryStore();
    remote = Remote();
    controller = ActivityAvailabilityController(
      store: store,
      remote: remote,
      clock: () => fetchedAt,
    );
    await bind(controller, a);
  });
  tearDown(() => controller.dispose());

  Future<void> restart({
    EixamSession identity = a,
    String backend = 'https://sdk.test',
  }) async {
    await controller.dispose();
    controller = ActivityAvailabilityController(store: store, remote: remote);
    await bind(controller, identity, backend: backend);
  }

  test(
    'get/watch never fetch; null differs from authoritative empty',
    () async {
      expect(await controller.getCachedActivityAvailability(), isNull);
      expect(await controller.watchActivityAvailability().first, isNull);
      expect(remote.calls, 0);
      remote.activities = [];
      final empty = await controller.refreshActivityAvailability();
      expect(empty.activities, isEmpty);
      expect(empty.fromCache, isFalse);
      expect(empty.fetchedAt, fetchedAt);
      expect(
        (await controller.getCachedActivityAvailability())!.activities,
        isEmpty,
      );
      expect(remote.calls, 1);
    },
  );

  test(
    'success persists only identity/ordered id-key/UTC/schema metadata',
    () async {
      remote.activities = [ski, mountain, ski];
      final fresh = await controller.refreshActivityAvailability();
      expect(fresh.fromCache, isFalse);
      expect(fresh.fetchedAt.isUtc, isTrue);
      expect(fresh.activities.map((v) => v.key), [
        ski.key,
        mountain.key,
        ski.key,
      ]);
      final json = jsonDecode(store.raw!) as Map;
      expect(json.keys.toSet(), {
        'schemaVersion',
        'ownerScope',
        'sdkUserId',
        'fetchedAt',
        'activities',
      });
      expect(store.raw, isNot(contains(a.userHash)));
      await restart();
      final restored = await controller.getCachedActivityAvailability();
      expect(restored!.fromCache, isTrue);
      expect(restored.fetchedAt, fresh.fetchedAt);
      expect(
        restored.activities.map((v) => v.key),
        fresh.activities.map((v) => v.key),
      );
      expect(() => restored.activities.clear(), throwsUnsupportedError);
      expect(remote.calls, 1);
    },
  );

  test('success empty replaces nonempty and survives restart', () async {
    await controller.refreshActivityAvailability();
    remote.activities = [];
    await controller.refreshActivityAvailability();
    await restart();
    expect(
      (await controller.getCachedActivityAvailability())!.activities,
      isEmpty,
    );
  });

  for (final failure in [
    const NetworkException('offline', 'offline'),
    const NetworkException('E_ACTIVITY_AVAILABILITY_RATE_LIMITED', '429'),
    const NetworkException('server', '500'),
    const ActivityAvailabilityException(
      'E_ACTIVITY_AVAILABILITY_INVALID_RESPONSE',
      'invalid',
    ),
  ]) {
    test(
      '${failure.runtimeType} refresh failure retains last-known-good',
      () async {
        await controller.refreshActivityAvailability();
        final raw = store.raw;
        remote.error = failure;
        await expectLater(
          controller.refreshActivityAvailability(),
          throwsA(same(failure)),
        );
        expect(store.raw, raw);
        expect(
          (await controller.getCachedActivityAvailability())!
              .activities
              .single
              .key,
          mountain.key,
        );
        remote.error = null;
        remote.activities = [ski];
        expect(
          (await controller.refreshActivityAvailability())
              .activities
              .single
              .key,
          ski.key,
        );
      },
    );
  }

  test(
    '401 clears current/disk and emits invalidation plus typed auth error',
    () async {
      await controller.refreshActivityAvailability();
      final values = <SdkActivityAvailability?>[];
      final errors = <Object>[];
      final sub = controller.watchActivityAvailability().listen(
        values.add,
        onError: errors.add,
      );
      await pumpEventQueue();
      remote.error = const AuthException('unauthorized', '401');
      await expectLater(
        controller.refreshActivityAvailability(),
        throwsA(isA<AuthException>()),
      );
      await pumpEventQueue();
      expect(values.last, isNull);
      expect(errors.single, isA<AuthException>());
      expect(store.raw, isNull);
      expect(await controller.getCachedActivityAvailability(), isNull);
      await sub.cancel();
    },
  );

  test(
    '401 with failed removal blocks cache reuse and allows cleanup retry',
    () async {
      await controller.refreshActivityAvailability();
      store.rejectRemove = true;
      remote.error = const AuthException('unauthorized', '401');
      await expectLater(
        controller.refreshActivityAvailability(),
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

  for (final corrupt in [
    '',
    '{broken',
    '[]',
    '{}',
    '{"schemaVersion":2}',
    '{"schemaVersion":1,"ownerScope":"scope","fetchedAt":"bad","activities":[]}',
  ]) {
    test(
      'corrupt/unsupported cache is an error, never false empty: $corrupt',
      () async {
        store.raw = corrupt;
        await expectLater(
          controller.getCachedActivityAvailability(),
          throwsA(availabilityError('RESTORE_FAILED')),
        );
        expect(store.raw, corrupt);
        final errors = <Object>[];
        final values = <SdkActivityAvailability?>[];
        final sub = controller.watchActivityAvailability().listen(
          values.add,
          onError: errors.add,
        );
        await pumpEventQueue();
        expect(values, isEmpty);
        expect(errors.single, availabilityError('RESTORE_FAILED'));
        await controller.refreshActivityAvailability();
        await pumpEventQueue();
        expect(values.single!.activities.single.key, 'mountain');
        expect(remote.calls, 1);
        await sub.cancel();
      },
    );
  }

  test('unreadable cache reports unusable and can later recover', () async {
    store.unreadable = true;
    await expectLater(
      controller.getCachedActivityAvailability(),
      throwsA(availabilityError('RESTORE_FAILED')),
    );
    store.unreadable = false;
    expect(
      (await controller.refreshActivityAvailability()).activities.single.key,
      'mountain',
    );
  });

  for (final throwWrite in [false, true]) {
    test(
      'rejected/thrown write preserves old snapshot ($throwWrite)',
      () async {
        await controller.refreshActivityAvailability();
        final raw = store.raw;
        store.rejectWrites = !throwWrite;
        store.throwWrites = throwWrite;
        remote.activities = [ski];
        final values = <SdkActivityAvailability?>[];
        final sub = controller.watchActivityAvailability().listen(
          values.add,
          onError: (Object _) {},
        );
        await pumpEventQueue();
        await expectLater(
          controller.refreshActivityAvailability(),
          throwsA(availabilityError('PERSISTENCE_FAILED')),
        );
        await pumpEventQueue();
        expect(store.raw, raw);
        expect(values, hasLength(1));
        expect(
          (await controller.getCachedActivityAvailability())!
              .activities
              .single
              .key,
          'mountain',
        );
        await sub.cancel();
      },
    );
    test(
      'lost/false acknowledgement accepted only after read-back ($throwWrite)',
      () async {
        store.rejectWrites = !throwWrite;
        store.throwWrites = throwWrite;
        store.applyBeforeFailure = true;
        expect(
          (await controller.refreshActivityAvailability()).fromCache,
          isFalse,
        );
        expect(store.reads, greaterThan(1));
      },
    );
  }

  test('write with unreadable verification does not publish', () async {
    store.failReadAfterWrite = true;
    await expectLater(
      controller.refreshActivityAvailability(),
      throwsA(availabilityError('PERSISTENCE_FAILED')),
    );
  });

  test(
    'watch seed and live update share storage queue without a lost replacement',
    () async {
      final gate = Completer<void>();
      store.nextRead = gate;
      final values = <SdkActivityAvailability?>[];
      final sub = controller.watchActivityAvailability().listen(values.add);
      await pumpEventQueue();
      final refresh = controller.refreshActivityAvailability();
      gate.complete();
      await refresh;
      await pumpEventQueue();
      expect(values, hasLength(2));
      expect(values.first, isNull);
      expect(values.last!.fromCache, isFalse);
      await sub.cancel();
    },
  );

  test(
    'concurrent refreshes coalesce and a failed attempt can retry',
    () async {
      final gate = Completer<List<SdkAvailableActivity>>();
      remote.next = gate;
      final first = controller.refreshActivityAvailability();
      final second = controller.refreshActivityAvailability();
      expect(identical(first, second), isTrue);
      await pumpEventQueue();
      expect(remote.calls, 1);
      gate.complete([ski]);
      expect(identical(await first, await second), isTrue);
      remote.error = const NetworkException('offline', 'offline');
      await expectLater(
        controller.refreshActivityAvailability(),
        throwsA(isA<NetworkException>()),
      );
      remote.error = null;
      await controller.refreshActivityAvailability();
      expect(remote.calls, 3);
    },
  );

  test(
    'checked SharedPreferences registration and real reload roundtrip',
    () async {
      SharedPreferences.setMockInitialValues({});
      final local = SharedPrefsSdkStore();
      final checked = SharedPrefsActivityAvailabilityStore(local);
      final other = ActivityAvailabilityController(
        store: checked,
        remote: remote,
      );
      addTearDown(other.dispose);
      await bind(other, a);
      await other.refreshActivityAvailability();
      expect(await checked.read(), isNotNull);
      expect(
        SharedPrefsSdkStore.checkedLocalUserDataKeys,
        contains(SharedPrefsSdkStore.activityAvailabilityKey),
      );
      expect(
        SharedPrefsSdkStore.localUserDataKeys,
        isNot(contains(SharedPrefsSdkStore.activityAvailabilityKey)),
      );
      await bind(other, null, clear: true);
      expect(await checked.read(), isNull);
    },
  );

  test(
    'two runtimes cannot overwrite each other; lease releases on dispose',
    () async {
      await controller.refreshActivityAvailability();
      final other = ActivityAvailabilityController(
        store: store,
        remote: remote,
      );
      addTearDown(other.dispose);
      await bind(other, b, restore: false);
      await expectLater(
        other.refreshActivityAvailability(),
        throwsA(availabilityError('UNAVAILABLE')),
      );
      expect(
        (await controller.getCachedActivityAvailability())!
            .activities
            .single
            .key,
        'mountain',
      );
      await controller.dispose();
      expect(await other.getCachedActivityAvailability(), isNull);
    },
  );

  for (final field in [
    'fetchedAt',
    'ownerScope',
    'activities',
    'sdkUserId',
    'schemaVersion',
  ]) {
    test('malformed envelope $field fails closed', () async {
      await controller.refreshActivityAvailability();
      final json = jsonDecode(store.raw!) as Map<String, dynamic>;
      json[field] = field == 'sdkUserId' ? '' : null;
      store.raw = jsonEncode(json);
      await restart();
      await expectLater(
        controller.getCachedActivityAvailability(),
        throwsA(availabilityError('RESTORE_FAILED')),
      );
    });
  }
}
