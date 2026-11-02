import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/tag_alerts_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tag_alert_test_support.dart';

const _ok = TagBatteryBand.ok;
const _medium = TagBatteryBand.medium;
const _b30 = TagBatteryBand.below30;
const _b10 = TagBatteryBand.below10;

void main() {
  late MemoryTagAlertStore store;
  late RecordingTagAlertNotifier notifier;
  late TagAlertsController controller;
  var epoch = 1;
  var n = 0;

  TagAlertsController build() =>
      TagAlertsController(store: store, notifier: notifier);

  Future<void> read(
    TagBatteryBand band, {
    String device = 'tag-1',
    String? key,
    String? alias = 'Roger TAG',
  }) => controller.onBatteryReading(
    deviceKey: device,
    deviceAlias: alias,
    band: band,
    sourceKey: key ?? 's${n++}',
    epoch: epoch,
  );

  Future<void> twice(TagBatteryBand band, {String device = 'tag-1'}) async {
    await read(band, device: device);
    await read(band, device: device);
  }

  List<TagAlertBatteryThreshold?> thresholds() =>
      notifier.shown.map((a) => a.batteryThreshold).toList();

  setUp(() async {
    store = MemoryTagAlertStore();
    notifier = RecordingTagAlertNotifier();
    epoch = 1;
    n = 0;
    controller = build();
    await bind(controller, sessionA);
  });
  tearDown(() => controller.dispose());

  Future<void> restart() async {
    await controller.dispose();
    controller = build();
    await bind(controller, sessionA);
    epoch++;
  }

  test('two live readings show one battery alert for that TAG', () async {
    await read(_b30);
    expect(notifier.shown, isEmpty);
    await read(_b30);
    expect(notifier.shown, hasLength(1));
    final alert = notifier.shown.single;
    expect(alert.kind, TagAlertKind.batteryLow);
    expect(alert.deviceId, 'tag-1');
    expect(alert.deviceAlias, 'Roger TAG');
    expect(alert.batteryThreshold, TagAlertBatteryThreshold.below30);
    await read(_b30);
    expect(notifier.shown, hasLength(1));
  });

  test('9 -> 11 -> 9 and 29 -> 31 -> 29 alert twice (confirmed)', () async {
    await twice(_ok);
    await twice(_b10);
    await twice(_b30);
    await twice(_b10);
    expect(thresholds(), [
      TagAlertBatteryThreshold.below10,
      TagAlertBatteryThreshold.below10,
    ]);
    notifier.shown.clear();
    await twice(_medium);
    await twice(_b30);
    await twice(_medium);
    await twice(_b30);
    expect(thresholds(), [
      TagAlertBatteryThreshold.below30,
      TagAlertBatteryThreshold.below30,
    ]);
  });

  test('a direct jump from >=30 to <10 shows a single 10 % alert', () async {
    await twice(_medium);
    await twice(_b10);
    expect(thresholds(), [TagAlertBatteryThreshold.below10]);
  });

  test('a stray reading across the boundary changes nothing', () async {
    await twice(_b30);
    await read(_medium);
    await twice(_b30);
    expect(notifier.shown, hasLength(1));
  });

  test(
    'the cycle survives restart: no re-fire after reconnecting low',
    () async {
      await twice(_b10);
      expect(notifier.shown, hasLength(1));
      final stored = jsonDecode(store.raw!) as Map<String, Object?>;
      expect((stored['cycles']! as Map).keys, ['tag-1']);
      await restart();
      await twice(_b10);
      await twice(_b30);
      expect(notifier.shown, hasLength(1));
      // A fresh drop after a confirmed recovery does alert again.
      await twice(_medium);
      await twice(_b10);
      expect(notifier.shown, hasLength(2));
    },
  );

  test(
    'reconnecting low with no cycle yet alerts after two readings',
    () async {
      epoch++;
      await read(_b10);
      expect(notifier.shown, isEmpty);
      await read(_b10);
      expect(thresholds(), [TagAlertBatteryThreshold.below10]);
    },
  );

  test('confirmation never spans connection epochs', () async {
    await read(_b30);
    epoch++;
    await read(_b30);
    expect(notifier.shown, isEmpty);
    await read(_b30);
    expect(notifier.shown, hasLength(1));
  });

  test('the same sample delivered twice is one reading', () async {
    await read(_b30, key: 'same');
    await read(_b30, key: 'same');
    expect(notifier.shown, isEmpty);
  });

  test('a confirmed ok removes the delivered alert, once', () async {
    await twice(_b30);
    notifier.calls.clear();
    await twice(_medium);
    expect(notifier.calls, isEmpty);
    await twice(_ok);
    expect(notifier.calls, ['cancel:tag-1:batteryLow']);
    await read(_ok);
    expect(notifier.calls, ['cancel:tag-1:batteryLow']);
  });

  test('devices are independent', () async {
    await twice(_b30, device: 'tag-1');
    await read(_b30, device: 'tag-2');
    expect(notifier.shown.map((a) => a.deviceId), ['tag-1']);
    await read(_b30, device: 'tag-2');
    expect(notifier.shown.map((a) => a.deviceId), ['tag-1', 'tag-2']);
  });

  group('settings', () {
    test('disabled battery alerts track the cycle but never alert', () async {
      await controller.updateTagAlertSettings(
        TagAlertSettings(deviceId: 'tag-1', batteryAlerts: false),
      );
      notifier.calls.clear();
      await twice(_b30);
      await twice(_b10);
      expect(notifier.shown, isEmpty);
      expect(store.raw, isNot(contains('"cycles"')));
    });

    test(
      're-enabling while still low alerts after two live readings',
      () async {
        await controller.updateTagAlertSettings(
          TagAlertSettings(deviceId: 'tag-1', batteryAlerts: false),
        );
        await twice(_b30);
        await controller.updateTagAlertSettings(
          TagAlertSettings(deviceId: 'tag-1'),
        );
        await read(_b30);
        expect(thresholds(), [TagAlertBatteryThreshold.below30]);
      },
    );
  });

  group('failures stay contained', () {
    test(
      'without a session readings are ignored and nothing is written',
      () async {
        await bind(controller, null);
        await twice(_b10);
        expect(notifier.shown, isEmpty);
        expect(store.raw, isNull);
      },
    );

    test('a notifier failure is surfaced, not marked, and retried', () async {
      notifier.failShow = true;
      final errors = <Object>[];
      final sub = controller
          .watchTagAlertSettings('tag-1')
          .listen((_) {}, onError: errors.add);
      await pumpEventQueue();
      await twice(_b30);
      await pumpEventQueue();
      expect(errors, isNotEmpty);
      expect(store.raw, isNot(contains('"cycles"')));
      // The alert was not consumed: the next confirmed reading delivers it.
      notifier.failShow = false;
      notifier.shown.clear();
      await read(_b30);
      expect(notifier.shown, hasLength(1));
      await read(_b30);
      expect(notifier.shown, hasLength(1));
      await sub.cancel();
    });

    test('a hung show is bounded and retried afterwards', () async {
      await controller.dispose();
      controller = TagAlertsController(
        store: store,
        notifier: notifier,
        notifierTimeout: const Duration(milliseconds: 50),
      );
      await bind(controller, sessionA);
      notifier.hangShow = true;
      await twice(_b30);
      expect(notifier.shown, hasLength(1)); // attempted, never completed
      expect(store.raw, isNot(contains('"cycles"')));
      notifier.hangShow = false;
      notifier.shown.clear();
      await read(_b30);
      expect(notifier.shown, hasLength(1));
      expect(store.raw, contains('"cycles"'));
    });

    test(
      'a persistence failure after the alert was shown never loses it',
      () async {
        store.rejectWrites = true;
        await read(_b30);
        await expectLater(
          read(_b30),
          throwsA(tagAlertsError('PERSISTENCE_FAILED')),
        );
        // Shown first (at-least-once); not marked, so it may repeat, never vanish.
        expect(notifier.shown, hasLength(1));
        store.rejectWrites = false;
        await read(_b30);
        expect(notifier.shown, hasLength(2));
        await read(_b30);
        expect(notifier.shown, hasLength(2));
      },
    );

    test(
      'a corrupt cycles field degrades to defaults with an explicit error',
      () async {
        store.raw = jsonEncode({
          'v': 1,
          'ownerScope': 'x',
          'devices': <String, Object?>{},
          'cycles': 'nope',
        });
        await restart();
        final errors = <Object>[];
        final sub = controller
            .watchTagAlertSettings('tag-1')
            .listen((_) {}, onError: errors.add);
        await pumpEventQueue();
        expect(errors.single, tagAlertsError('RESTORE_FAILED'));
        await twice(_b30);
        expect(notifier.shown, hasLength(1));
        await sub.cancel();
      },
    );
  });

  group('notification permission', () {
    late CountingPermissionGateway permissions;

    setUp(() async {
      await controller.dispose();
      permissions = CountingPermissionGateway();
      controller = TagAlertsController(
        store: store,
        notifier: notifier,
        permissions: permissions,
      );
      await bind(controller, sessionA);
    });

    for (final blocked in [
      TagAlertPermissionState.denied,
      TagAlertPermissionState.permanentlyDenied,
      TagAlertPermissionState.notDetermined,
    ]) {
      test('$blocked: nothing is shown or marked; granting later alerts '
          'on the next live reading', () async {
        permissions.next = blocked;
        await twice(_b30);
        await read(_b30);
        expect(notifier.shown, isEmpty);
        expect(store.raw, isNot(contains('"cycles"')));
        permissions.next = TagAlertPermissionState.granted;
        await read(_b30);
        expect(thresholds(), [TagAlertBatteryThreshold.below30]);
        await read(_b30);
        expect(notifier.shown, hasLength(1));
      });
    }

    test('rearming still works while notifications are blocked', () async {
      permissions.next = TagAlertPermissionState.granted;
      await twice(_b30);
      permissions.next = TagAlertPermissionState.denied;
      await twice(_medium);
      expect(store.raw, isNot(contains('"cycles"')));
      permissions.next = TagAlertPermissionState.granted;
      await twice(_b30);
      expect(notifier.shown, hasLength(2));
    });

    test(
      'unsupported platforms and failing checks do not block delivery',
      () async {
        permissions.next = TagAlertPermissionState.unsupported;
        await twice(_b30);
        expect(notifier.shown, hasLength(1));
        permissions.failState = true;
        await twice(_medium);
        await twice(_b30);
        expect(notifier.shown, hasLength(2));
      },
    );

    test('the permission is only consulted when an alert would fire', () async {
      permissions.next = TagAlertPermissionState.granted;
      await twice(_ok);
      await twice(_medium);
      expect(permissions.stateCalls, 0);
      await twice(_b30);
      expect(permissions.stateCalls, 1);
    });
  });

  group('cleanup', () {
    test(
      'logout wipes the cycle and streak; the next login alerts afresh',
      () async {
        await twice(_b30);
        await read(_medium);
        await bind(controller, null);
        expect(store.raw, isNull);
        await bind(controller, sessionA, restore: false);
        notifier.shown.clear();
        await read(_b30); // streak was wiped: this is reading 1
        expect(notifier.shown, isEmpty);
        await read(_b30);
        expect(notifier.shown, hasLength(1));
      },
    );

    test(
      'unpair removes the device cycle and streak, keeping others',
      () async {
        await twice(_b30, device: 'tag-1');
        await twice(_b30, device: 'tag-2');
        notifier.shown.clear();
        await controller.onDeviceUnpaired('tag-1');
        final stored = jsonDecode(store.raw!) as Map<String, Object?>;
        expect((stored['cycles']! as Map).keys, ['tag-2']);
        await twice(_b30, device: 'tag-1');
        expect(notifier.shown.map((a) => a.deviceId), ['tag-1']);
        await twice(_b30, device: 'tag-2');
        expect(notifier.shown.map((a) => a.deviceId), ['tag-1']);
      },
    );

    test(
      'an identity change mid-streak does not carry the streak over',
      () async {
        await read(_b30);
        await bind(controller, sessionB, restore: false);
        await read(_b30);
        expect(notifier.shown, isEmpty);
      },
    );
  });
}
