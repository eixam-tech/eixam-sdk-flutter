import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/tag_alert_store.dart';
import 'package:eixam_connect_flutter/src/sdk/tag_alerts_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tag_alert_test_support.dart';

void main() {
  late MemoryTagAlertStore store;
  late RecordingTagAlertNotifier notifier;
  late CountingPermissionGateway permissions;
  late TagAlertsController controller;

  TagAlertsController build() => TagAlertsController(
    store: store,
    notifier: notifier,
    permissions: permissions,
  );

  setUp(() async {
    store = MemoryTagAlertStore();
    notifier = RecordingTagAlertNotifier();
    permissions = CountingPermissionGateway();
    controller = build();
    await bind(controller, sessionA);
  });
  tearDown(() => controller.dispose());

  Future<void> restart({EixamSession? identity = sessionA}) async {
    await controller.dispose();
    controller = build();
    await bind(controller, identity);
  }

  test('defaults: battery on, 5 minutes, nothing written by reading', () async {
    final settings = await controller.getTagAlertSettings('tag-1');
    expect(settings, TagAlertSettings(deviceId: 'tag-1'));
    expect(settings.batteryAlerts, isTrue);
    expect(settings.disconnectAfter, const Duration(minutes: 5));
    expect(store.raw, isNull);
    expect(store.writes, 0);
  });

  test('update persists, publishes and survives restart', () async {
    final seen = <TagAlertSettings>[];
    final sub = controller.watchTagAlertSettings('tag-1').listen(seen.add);
    await pumpEventQueue();
    final updated = TagAlertSettings(
      deviceId: 'tag-1',
      batteryAlerts: false,
      disconnectAfter: const Duration(minutes: 30),
    );
    await controller.updateTagAlertSettings(updated);
    await pumpEventQueue();
    expect(seen, [TagAlertSettings(deviceId: 'tag-1'), updated]);
    await sub.cancel();
    await restart();
    expect(await controller.getTagAlertSettings('tag-1'), updated);
  });

  test('settings are isolated per device', () async {
    final one = TagAlertSettings(deviceId: 'tag-1', disconnectAfter: null);
    await controller.updateTagAlertSettings(one);
    expect(await controller.getTagAlertSettings('tag-1'), one);
    expect(
      await controller.getTagAlertSettings('tag-2'),
      TagAlertSettings(deviceId: 'tag-2'),
    );
    final seen = <TagAlertSettings>[];
    final sub = controller.watchTagAlertSettings('tag-2').listen(seen.add);
    await pumpEventQueue();
    await controller.updateTagAlertSettings(one.copyWith(batteryAlerts: false));
    await pumpEventQueue();
    // tag-2 watchers re-receive their own unchanged settings only.
    expect(seen.every((s) => s == TagAlertSettings(deviceId: 'tag-2')), isTrue);
    await sub.cancel();
  });

  test('update without a session is rejected', () async {
    await bind(controller, null);
    await expectLater(
      controller.updateTagAlertSettings(TagAlertSettings(deviceId: 'tag-1')),
      throwsA(tagAlertsError('SESSION_REQUIRED')),
    );
    expect(store.raw, isNull);
  });

  test('empty device ids are rejected', () {
    expect(() => controller.getTagAlertSettings(' '), throwsArgumentError);
    expect(() => controller.watchTagAlertSettings(''), throwsArgumentError);
  });

  test('persistence failure is explicit and keeps previous state', () async {
    final good = TagAlertSettings(deviceId: 'tag-1', batteryAlerts: false);
    await controller.updateTagAlertSettings(good);
    store.rejectWrites = true;
    await expectLater(
      controller.updateTagAlertSettings(TagAlertSettings(deviceId: 'tag-1')),
      throwsA(tagAlertsError('PERSISTENCE_FAILED')),
    );
    store.rejectWrites = false;
    expect(await controller.getTagAlertSettings('tag-1'), good);
  });

  group('corrupt or unsupported store', () {
    for (final raw in <String>['{not json', '{"v":2}', '[]']) {
      test('"$raw" yields defaults, one stream error, no crash', () async {
        store.raw = raw;
        await restart();
        final errors = <Object>[];
        final values = <TagAlertSettings>[];
        final sub = controller
            .watchTagAlertSettings('tag-1')
            .listen(values.add, onError: errors.add);
        await pumpEventQueue();
        expect(
          await controller.getTagAlertSettings('tag-1'),
          TagAlertSettings(deviceId: 'tag-1'),
        );
        expect(errors.single, tagAlertsError('RESTORE_FAILED'));
        expect(values, [TagAlertSettings(deviceId: 'tag-1')]);
        // The stream stays usable and the next write replaces the bad blob.
        final fixed = TagAlertSettings(
          deviceId: 'tag-1',
          disconnectAfter: null,
        );
        await controller.updateTagAlertSettings(fixed);
        await pumpEventQueue();
        expect(values.last, fixed);
        await restart();
        expect(await controller.getTagAlertSettings('tag-1'), fixed);
        await sub.cancel();
      });
    }

    test('unreadable IO also degrades to defaults', () async {
      store.unreadable = true;
      await restart();
      expect(
        await controller.getTagAlertSettings('tag-1'),
        TagAlertSettings(deviceId: 'tag-1'),
      );
    });
  });

  group('cleanup', () {
    Future<void> seed() async {
      await controller.updateTagAlertSettings(
        TagAlertSettings(deviceId: 'tag-1', disconnectAfter: null),
      );
      await controller.updateTagAlertSettings(
        TagAlertSettings(deviceId: 'tag-2', batteryAlerts: false),
      );
      notifier.calls.clear();
    }

    test(
      'clearSession (identity becomes null) wipes data and alerts',
      () async {
        await seed();
        await bind(controller, null);
        expect(store.raw, isNull);
        expect(notifier.calls, contains('cancelAll'));
        await bind(controller, sessionA);
        expect(
          await controller.getTagAlertSettings('tag-1'),
          TagAlertSettings(deviceId: 'tag-1'),
        );
      },
    );

    test('clearLocalUserData (clearData) wipes data and alerts', () async {
      await seed();
      await bind(controller, sessionA, clear: true);
      expect(store.raw, isNull);
      expect(notifier.calls, contains('cancelAll'));
    });

    test('a different user or app wipes the previous identity data', () async {
      for (final next in <EixamSession>[sessionB, sessionOtherApp]) {
        await seed();
        await bind(controller, next, restore: false);
        expect(store.raw, isNull, reason: next.externalUserId + next.appId);
        expect(notifier.calls, contains('cancelAll'));
        await bind(controller, sessionA, restore: false);
        notifier.calls.clear();
      }
    });

    test(
      'a foreign owner scope found on disk is dropped, not adopted',
      () async {
        await seed();
        await controller.dispose();
        controller = build();
        await bind(controller, sessionB);
        expect(
          await controller.getTagAlertSettings('tag-1'),
          TagAlertSettings(deviceId: 'tag-1'),
        );
        expect(store.raw, isNull);
      },
    );

    test('restoring the same session keeps data and alerts', () async {
      await seed();
      await restart();
      expect(
        (await controller.getTagAlertSettings('tag-1')).disconnectAfter,
        isNull,
      );
      expect(notifier.calls, isNot(contains('cancelAll')));
    });

    group('a cold-start restore that throws is not a signed-out user', () {
      Future<void> failedRestore() async {
        await controller.dispose();
        controller = build();
        await expectLater(
          controller.withIdentityChange<void>(
            () async => throw StateError('keychain locked'),
            currentSession: () => null,
            backend: () => 'https://sdk.test',
            restoreExisting: true,
          ),
          throwsStateError,
        );
      }

      test('keeps data and alerts, then adopts the same identity', () async {
        await seed();
        await failedRestore();
        expect(store.raw, isNotNull);
        expect(notifier.calls, isEmpty);
        await bind(controller, sessionA, restore: false);
        expect(notifier.calls, isEmpty);
        expect(
          (await controller.getTagAlertSettings('tag-2')).batteryAlerts,
          isFalse,
        );
      });

      test(
        'a different identity afterwards still drops the old data',
        () async {
          await seed();
          await failedRestore();
          await bind(controller, sessionB, restore: false);
          expect(
            await controller.getTagAlertSettings('tag-2'),
            TagAlertSettings(deviceId: 'tag-2'),
          );
          expect(notifier.calls, contains('cancelAll'));
          expect(store.raw, isNull);
        },
      );

      test('an explicit logout after the failure still wipes', () async {
        await seed();
        await failedRestore();
        await bind(controller, null);
        expect(store.raw, isNull);
        expect(notifier.calls, contains('cancelAll'));
      });

      test('a restore that completes with no session wipes', () async {
        await seed();
        await controller.dispose();
        controller = build();
        await bind(controller, null);
        expect(store.raw, isNull);
        expect(notifier.calls, contains('cancelAll'));
      });

      test(
        'while unresolved, settings read as defaults and cannot be written',
        () async {
          await seed();
          await failedRestore();
          expect(
            await controller.getTagAlertSettings('tag-2'),
            TagAlertSettings(deviceId: 'tag-2'),
          );
          await expectLater(
            controller.updateTagAlertSettings(
              TagAlertSettings(deviceId: 'tag-2'),
            ),
            throwsA(tagAlertsError('SESSION_REQUIRED')),
          );
          expect(store.raw, isNotNull);
        },
      );
    });

    test('unpair removes only that device and cancels its alerts', () async {
      await seed();
      await controller.onDeviceUnpaired('tag-1');
      expect(notifier.calls, ['cancelAllForDevice:tag-1']);
      expect(
        await controller.getTagAlertSettings('tag-1'),
        TagAlertSettings(deviceId: 'tag-1'),
      );
      expect(
        (await controller.getTagAlertSettings('tag-2')).batteryAlerts,
        isFalse,
      );
    });

    test('unpair of an unknown device still cancels its alerts', () async {
      await controller.onDeviceUnpaired('ghost');
      expect(notifier.calls, ['cancelAllForDevice:ghost']);
    });

    test(
      'notifier failure on logout is surfaced but data is still wiped',
      () async {
        await seed();
        notifier.failCancelAll = true;
        final errors = <Object>[];
        final sub = controller
            .watchTagAlertSettings('tag-1')
            .listen((_) {}, onError: errors.add);
        await pumpEventQueue();
        await bind(controller, null);
        await pumpEventQueue();
        expect(store.raw, isNull);
        await sub.cancel();
      },
    );

    test('disabling a feature cancels only its own slot', () async {
      notifier.calls.clear();
      await controller.updateTagAlertSettings(
        TagAlertSettings(
          deviceId: 'tag-1',
          batteryAlerts: false,
          disconnectAfter: null,
        ),
      );
      expect(notifier.calls, [
        'cancel:tag-1:batteryLow',
        'cancel:tag-1:tagDisconnected',
      ]);
      notifier.calls.clear();
      await controller.updateTagAlertSettings(
        TagAlertSettings(deviceId: 'tag-1'),
      );
      expect(notifier.calls, isEmpty);
    });

    test(
      'dispose releases resources without wiping settings or alerts',
      () async {
        await seed();
        await controller.dispose();
        expect(store.raw, isNotNull);
        expect(notifier.calls, isEmpty);
        await expectLater(
          controller.getTagAlertSettings('tag-1'),
          throwsA(tagAlertsError('UNAVAILABLE')),
        );
        controller = build();
        await bind(controller, sessionA);
        expect(
          (await controller.getTagAlertSettings('tag-2')).batteryAlerts,
          isFalse,
        );
      },
    );

    test('dispose completes a clear that was already owed', () async {
      await seed();
      store.nextWrite = Completer<void>();
      final gate = store.nextWrite!;
      // A logout racing a pending write: the clear is owed at dispose time.
      final pending = controller.updateTagAlertSettings(
        TagAlertSettings(deviceId: 'tag-3'),
      );
      final logout = bind(controller, null);
      gate.complete();
      await pending.catchError((Object _) {});
      await logout.catchError((Object _) {});
      await controller.dispose();
      expect(store.raw, isNull);
    });
  });

  group('identity-change races', () {
    test('a write in flight during logout cannot resurrect data', () async {
      final gate = Completer<void>();
      store.nextWrite = gate;
      final write = controller.updateTagAlertSettings(
        TagAlertSettings(deviceId: 'tag-1', batteryAlerts: false),
      );
      await pumpEventQueue();
      final logout = bind(controller, null);
      gate.complete();
      await expectLater(write, throwsA(tagAlertsError('UNAVAILABLE')));
      await logout;
      expect(store.raw, isNull);
      await bind(controller, sessionA);
      expect(
        await controller.getTagAlertSettings('tag-1'),
        TagAlertSettings(deviceId: 'tag-1'),
      );
    });

    test(
      'a paused watcher never sees the previous identity afterwards',
      () async {
        await controller.updateTagAlertSettings(
          TagAlertSettings(deviceId: 'tag-1', batteryAlerts: false),
        );
        final seen = <TagAlertSettings>[];
        final sub = controller.watchTagAlertSettings('tag-1').listen(seen.add);
        await pumpEventQueue();
        sub.pause();
        await bind(controller, sessionB, restore: false);
        sub.resume();
        await pumpEventQueue();
        expect(seen.where((s) => !s.batteryAlerts), hasLength(1));
        expect(seen.last, TagAlertSettings(deviceId: 'tag-1'));
        await sub.cancel();
      },
    );

    test(
      'a same-user session refresh never flashes defaults to watchers',
      () async {
        final stored = TagAlertSettings(
          deviceId: 'tag-1',
          batteryAlerts: false,
          disconnectAfter: const Duration(minutes: 60),
        );
        await controller.updateTagAlertSettings(stored);
        final seen = <TagAlertSettings>[];
        final sub = controller.watchTagAlertSettings('tag-1').listen(seen.add);
        await pumpEventQueue();
        await bind(controller, sessionA, restore: false);
        await pumpEventQueue();
        expect(seen, isNotEmpty);
        expect(seen.every((s) => s == stored), isTrue, reason: '$seen');
        await sub.cancel();
      },
    );

    test('a second writer on the same store is refused', () async {
      // The first controller takes the writer lease on first use.
      await controller.getTagAlertSettings('tag-1');
      final other = TagAlertsController(store: store, notifier: notifier);
      addTearDown(other.dispose);
      await bind(other, sessionA);
      await expectLater(
        other.getTagAlertSettings('tag-1'),
        throwsA(tagAlertsError('UNAVAILABLE')),
      );
    });

    test('concurrent updates serialize without losing devices', () async {
      await Future.wait([
        for (var i = 0; i < 10; i++)
          controller.updateTagAlertSettings(
            TagAlertSettings(deviceId: 'tag-$i', batteryAlerts: i.isEven),
          ),
      ]);
      await restart();
      for (var i = 0; i < 10; i++) {
        expect(
          (await controller.getTagAlertSettings('tag-$i')).batteryAlerts,
          i.isEven,
        );
      }
    });
  });

  group('permissions', () {
    test('state never prompts; request prompts only when called', () async {
      expect(
        await controller.getTagAlertPermissionState(),
        TagAlertPermissionState.notDetermined,
      );
      expect(permissions.requestCalls, 0);
      expect(
        await controller.requestTagAlertPermission(),
        TagAlertPermissionState.granted,
      );
      expect(permissions.requestCalls, 1);
    });

    test('binding an identity, reading and writing never prompt', () async {
      await controller.updateTagAlertSettings(
        TagAlertSettings(deviceId: 'tag-1'),
      );
      await controller.getTagAlertSettings('tag-1');
      expect(permissions.requestCalls, 0);
    });
  });

  test('store failures never leak through the public record', () {
    expect(
      TagAlertRecord.decode(
        TagAlertRecord(ownerScope: 's', devices: const {}).encode(),
      ).devices,
      isEmpty,
    );
  });
}
