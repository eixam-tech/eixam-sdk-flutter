import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/tag_alerts_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tag_alert_test_support.dart';

final _t0 = DateTime.utc(2026, 11, 2, 12);
const _five = Duration(minutes: 5);
const _key = 'AA:BB:CC:DD:EE:01';

TagLinkSnapshot up(
  DateTime at, {
  String key = _key,
  bool sos = false,
  bool background = false,
  TagAlertPosition? position,
}) => TagLinkSnapshot(
  deviceKey: key,
  deviceAlias: 'Roger TAG',
  observedAt: at,
  paired: true,
  connected: true,
  sosActive: sos,
  backgroundDisarm: background,
  lastTagPosition: position,
);

TagLinkSnapshot down(
  DateTime at, {
  required DateTime since,
  String key = _key,
  TagDisconnectCause cause = TagDisconnectCause.unexpected,
  DateTime? hold,
}) => TagLinkSnapshot(
  deviceKey: key,
  observedAt: at,
  paired: true,
  connected: false,
  disconnectedSince: since,
  cause: cause,
  holdUntil: hold,
);

void main() {
  late MemoryTagAlertStore store;
  late RecordingTagAlertNotifier notifier;
  late CountingPermissionGateway permissions;
  late TagAlertsController controller;
  late DateTime now;

  TagAlertsController build({Duration? timeout}) => TagAlertsController(
    store: store,
    notifier: notifier,
    permissions: permissions,
    clock: () => now,
    notifierTimeout: timeout ?? TagAlertsController.defaultNotifierTimeout,
  );

  Iterable<String> schedules() =>
      notifier.calls.where((c) => c.startsWith('schedule:'));

  setUp(() async {
    store = MemoryTagAlertStore();
    notifier = RecordingTagAlertNotifier();
    permissions = CountingPermissionGateway()
      ..next = TagAlertPermissionState.granted;
    now = _t0;
    controller = build();
    await bind(controller, sessionA);
  });
  tearDown(() => controller.dispose());

  test('a connected TAG arms a dead-man alert at now + X + slack', () async {
    await controller.onLinkSnapshot(up(_t0));
    final scheduled = notifier.scheduled.single;
    expect(scheduled.alert.kind, TagAlertKind.tagDisconnected);
    expect(scheduled.alert.deviceId, _key);
    expect(scheduled.alert.deviceAlias, 'Roger TAG');
    expect(scheduled.alert.elapsed, _five);
    expect(scheduled.at, _t0.add(_five).add(const Duration(seconds: 75)));
  });

  test(
    'the alert carries the last TAG position, never a phone position',
    () async {
      final position = TagAlertPosition(
        latitude: 42.5,
        longitude: 1.5,
        timestamp: _t0,
        source: SdkLocationSource.connectedDevice,
      );
      await controller.onLinkSnapshot(up(_t0, position: position));
      expect(notifier.scheduled.single.alert.lastTagPosition, position);
    },
  );

  group('throttle and cost', () {
    test('15 s ticks for an hour cost one push per interval', () async {
      for (var s = 0; s <= 3600; s += 15) {
        await controller.onLinkSnapshot(up(_t0.add(Duration(seconds: s))));
      }
      // 3600 s / 75 s interval -> at most 49 pushes instead of 241 ticks.
      expect(schedules().length, lessThanOrEqualTo(3600 ~/ 75 + 1));
      expect(schedules().length, greaterThan(40));
      // Only the very first arming clears a stale alert; pushes replace in place.
      expect(notifier.calls.where((c) => c.startsWith('cancel')), hasLength(1));
    });

    test('a burst of snapshots is coalesced to one evaluation', () async {
      final futures = [
        for (var i = 0; i < 50; i++)
          controller.onLinkSnapshot(up(_t0.add(Duration(seconds: i)))),
      ];
      await Future.wait(futures);
      expect(schedules().length, 1);
      // The newest snapshot won.
      expect(
        notifier.scheduled.single.at,
        _t0
            .add(const Duration(seconds: 49))
            .add(_five)
            .add(const Duration(seconds: 75)),
      );
    });

    test('other operations are not starved by a stream of ticks', () async {
      final ticks = <Future<void>>[];
      final order = <String>[];
      for (var i = 0; i < 100; i++) {
        ticks.add(
          controller.onLinkSnapshot(up(_t0.add(Duration(seconds: i * 15)))),
        );
        if (i == 50) {
          unawaited(
            controller
                .updateTagAlertSettings(
                  TagAlertSettings(deviceId: 'other', batteryAlerts: false),
                )
                .then((_) => order.add('update')),
          );
        }
      }
      await Future.wait(ticks);
      await pumpEventQueue();
      expect(order, ['update']);
      expect(
        (await controller.getTagAlertSettings('other')).batteryAlerts,
        isFalse,
      );
    });
  });

  group('permission', () {
    for (final blocked in [
      TagAlertPermissionState.denied,
      TagAlertPermissionState.permanentlyDenied,
      TagAlertPermissionState.notDetermined,
    ]) {
      test('$blocked: the lease is not armed; granting arms it', () async {
        permissions.next = blocked;
        await controller.onLinkSnapshot(up(_t0));
        expect(notifier.scheduled, isEmpty);
        permissions.next = TagAlertPermissionState.granted;
        await controller.requestTagAlertPermission();
        await pumpEventQueue();
        expect(notifier.scheduled, hasLength(1));
      });
    }

    test('the check is cached for 60 s and rechecked after', () async {
      await controller.onLinkSnapshot(up(_t0));
      for (var s = 15; s < 60; s += 15) {
        now = _t0.add(Duration(seconds: s));
        await controller.onLinkSnapshot(up(now));
      }
      expect(permissions.stateCalls, 1);
      now = _t0.add(const Duration(seconds: 61));
      await controller.onLinkSnapshot(up(now));
      expect(permissions.stateCalls, 2);
    });

    test('a revoked permission disarms at the next recheck', () async {
      await controller.onLinkSnapshot(up(_t0));
      permissions.next = TagAlertPermissionState.denied;
      now = _t0.add(const Duration(seconds: 90));
      notifier.calls.clear();
      await controller.onLinkSnapshot(up(now));
      expect(notifier.calls, contains('cancel:$_key:tagDisconnected'));
      expect(schedules(), isEmpty);
    });
  });

  group('link transitions', () {
    test(
      'an observed unexpected drop reschedules to exactly since + X',
      () async {
        await controller.onLinkSnapshot(up(_t0));
        final since = _t0.add(const Duration(seconds: 100));
        await controller.onLinkSnapshot(down(since, since: since));
        expect(notifier.scheduled.last.at, since.add(_five));
        final before = notifier.scheduled.length;
        await controller.onLinkSnapshot(
          down(since.add(const Duration(seconds: 30)), since: since),
        );
        expect(notifier.scheduled.length, before, reason: 'no repeat');
      },
    );

    test('a reconnect clears the alert and re-arms', () async {
      await controller.onLinkSnapshot(up(_t0));
      final since = _t0.add(const Duration(seconds: 100));
      await controller.onLinkSnapshot(down(since, since: since));
      notifier.calls.clear();
      await controller.onLinkSnapshot(
        up(since.add(const Duration(minutes: 7))),
      );
      expect(notifier.calls, [
        'cancel:$_key:tagDisconnected',
        'schedule:$_key:tagDisconnected',
      ]);
    });

    test(
      'manual disconnects and expected holds cancel and stay quiet',
      () async {
        await controller.onLinkSnapshot(up(_t0));
        final since = _t0.add(const Duration(seconds: 100));
        notifier.calls.clear();
        await controller.onLinkSnapshot(
          down(since, since: since, cause: TagDisconnectCause.manual),
        );
        expect(notifier.calls, contains('cancel:$_key:tagDisconnected'));
        expect(schedules(), isEmpty);
      },
    );

    test('Bluetooth off raises the bluetoothOff kind', () async {
      await controller.onLinkSnapshot(up(_t0));
      final since = _t0.add(const Duration(seconds: 100));
      await controller.onLinkSnapshot(
        down(since, since: since, cause: TagDisconnectCause.bluetoothOff),
      );
      final alert = notifier.scheduled.last.alert;
      expect(alert.kind, TagAlertKind.bluetoothOff);
      expect(alert.elapsed, isNull);
    });

    test(
      'iOS background: the lease is dropped, a woken drop still arms',
      () async {
        await controller.onLinkSnapshot(up(_t0));
        notifier.calls.clear();
        await controller.onLinkSnapshot(
          up(_t0.add(const Duration(seconds: 20)), background: true),
        );
        expect(notifier.calls, contains('cancel:$_key:tagDisconnected'));
        final since = _t0.add(const Duration(minutes: 3));
        await controller.onLinkSnapshot(
          TagLinkSnapshot(
            deviceKey: _key,
            observedAt: since,
            paired: true,
            connected: false,
            disconnectedSince: since,
            backgroundDisarm: true,
          ),
        );
        expect(notifier.scheduled.last.at, since.add(_five));
      },
    );
  });

  group('SOS', () {
    test('cancels the lease and re-arms when the SOS ends', () async {
      await controller.onLinkSnapshot(up(_t0));
      notifier.calls.clear();
      await controller.onLinkSnapshot(
        up(_t0.add(const Duration(seconds: 30)), sos: true),
      );
      expect(notifier.calls, contains('cancel:$_key:tagDisconnected'));
      notifier.calls.clear();
      await controller.onLinkSnapshot(
        up(_t0.add(const Duration(minutes: 5)), sos: true),
      );
      expect(notifier.calls, isEmpty);
      await controller.onLinkSnapshot(up(_t0.add(const Duration(minutes: 6))));
      expect(schedules(), hasLength(1));
    });
  });

  group('settings', () {
    test('"never" removes the alert and nothing arms', () async {
      await controller.onLinkSnapshot(up(_t0));
      await controller.updateTagAlertSettings(
        TagAlertSettings(deviceId: _key, disconnectAfter: null),
      );
      await pumpEventQueue();
      expect(notifier.calls, contains('cancel:$_key:tagDisconnected'));
      notifier.calls.clear();
      await controller.onLinkSnapshot(up(_t0.add(const Duration(minutes: 3))));
      expect(schedules(), isEmpty);
    });

    test('a new delay re-arms immediately with the new value', () async {
      await controller.onLinkSnapshot(up(_t0));
      await controller.updateTagAlertSettings(
        TagAlertSettings(
          deviceId: _key,
          disconnectAfter: const Duration(minutes: 30),
        ),
      );
      await pumpEventQueue();
      final last = notifier.scheduled.last;
      expect(last.alert.elapsed, const Duration(minutes: 30));
      expect(
        last.at,
        _t0.add(const Duration(minutes: 30)).add(const Duration(seconds: 450)),
      );
    });
  });

  group('rekey, unpair, logout', () {
    test(
      'rekey cancels the old key, forgets its lease and announces it',
      () async {
        await controller.onLinkSnapshot(up(_t0, key: 'old'));
        final events = <TagAlertRekey>[];
        final sub = controller.rekeyEvents.listen(events.add);
        notifier.calls.clear();
        await controller.rekeyDevice('old', 'new');
        await pumpEventQueue();
        expect(notifier.calls, ['cancelAllForDevice:old']);
        expect(events.single.from, 'old');
        expect(events.single.to, 'new');
        // The owner re-arms under the new key.
        await controller.onLinkSnapshot(
          up(_t0.add(const Duration(seconds: 5)), key: 'new'),
        );
        expect(notifier.scheduled.last.alert.deviceId, 'new');
        // And the old key's lease state is gone: it arms from scratch.
        notifier.calls.clear();
        await controller.onLinkSnapshot(
          up(_t0.add(const Duration(seconds: 10)), key: 'old'),
        );
        expect(schedules(), hasLength(1));
        await sub.cancel();
      },
    );

    test(
      'unpair drops the lease; logout wipes and ignores later ticks',
      () async {
        await controller.onLinkSnapshot(up(_t0));
        await controller.onDeviceUnpaired(_key);
        notifier.calls.clear();
        await controller.onLinkSnapshot(
          up(_t0.add(const Duration(seconds: 5))),
        );
        expect(schedules(), hasLength(1), reason: 'fresh lease after unpair');
        await bind(controller, null);
        notifier.calls.clear();
        await controller.onLinkSnapshot(
          up(_t0.add(const Duration(minutes: 1))),
        );
        expect(
          notifier.calls,
          isEmpty,
          reason: 'no session, nothing scheduled',
        );
      },
    );
  });

  group('failures stay contained and bounded', () {
    test('a failing schedule is surfaced, not adopted, and retried', () async {
      final errors = <Object>[];
      final sub = controller
          .watchTagAlertSettings(_key)
          .listen((_) {}, onError: errors.add);
      await pumpEventQueue();
      notifier.failSchedule = true;
      await controller.onLinkSnapshot(up(_t0));
      await pumpEventQueue();
      expect(errors, isNotEmpty);
      notifier.failSchedule = false;
      await controller.onLinkSnapshot(up(_t0.add(const Duration(seconds: 15))));
      expect(notifier.scheduled, hasLength(2), reason: 'retried on next tick');
      await controller.onLinkSnapshot(up(_t0.add(const Duration(seconds: 30))));
      expect(notifier.scheduled, hasLength(2), reason: 'then throttled');
      await sub.cancel();
    });

    test('a hung schedule is bounded and never blocks the tail', () async {
      await controller.dispose();
      controller = build(timeout: const Duration(milliseconds: 50));
      await bind(controller, sessionA);
      notifier.hangSchedule = true;
      final watch = Stopwatch()..start();
      await controller.onLinkSnapshot(up(_t0));
      await controller.updateTagAlertSettings(
        TagAlertSettings(deviceId: 'x', batteryAlerts: false),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('pending cleanup is retried before a lease evaluation', () async {
      await controller.onLinkSnapshot(up(_t0));
      notifier.failCancelAll = true;
      await bind(controller, null);
      await bind(controller, sessionA, restore: false);
      notifier.failCancelAll = false;
      notifier.calls.clear();
      await controller.onLinkSnapshot(up(_t0.add(const Duration(minutes: 1))));
      expect(notifier.calls.first, 'cancelAll');
      expect(schedules(), hasLength(1));
    });

    test('battery alert slots are never touched by the lease', () async {
      await controller.onLinkSnapshot(up(_t0));
      final since = _t0.add(const Duration(seconds: 100));
      await controller.onLinkSnapshot(
        down(since, since: since, cause: TagDisconnectCause.manual),
      );
      expect(notifier.calls.where((c) => c.contains('batteryLow')), isEmpty);
    });
  });
  group('background drop fast path', backgroundDropControllerTests);
}

void backgroundDropControllerTests() {
  late MemoryTagAlertStore store;
  late RecordingTagAlertNotifier notifier;
  late CountingPermissionGateway permissions;
  late TagAlertsController controller;
  late DateTime now;
  late List<String> logs;

  TagLinkSnapshot drop(DateTime at) => TagLinkSnapshot(
    deviceKey: _key,
    observedAt: at,
    paired: true,
    connected: false,
    disconnectedSince: at,
    backgroundDisarm: true,
    backgrounded: true,
  );

  setUp(() async {
    store = MemoryTagAlertStore();
    notifier = RecordingTagAlertNotifier();
    permissions = CountingPermissionGateway()
      ..next = TagAlertPermissionState.granted;
    now = _t0;
    logs = <String>[];
    controller = TagAlertsController(
      store: store,
      notifier: notifier,
      permissions: permissions,
      clock: () => now,
      log: logs.add,
    );
    await bind(controller, sessionA);
  });
  tearDown(() => controller.dispose());

  group('background drop: nothing delays the schedule', () {
    test('pending cleanup is retried after the schedule, not before', () async {
      await controller.onLinkSnapshot(up(_t0));
      notifier.failCancelAll = true;
      await bind(controller, null);
      await bind(controller, sessionA, restore: false);
      notifier.failCancelAll = false;
      notifier.calls.clear();
      await controller.onLinkSnapshot(
        drop(_t0.add(const Duration(minutes: 1))),
      );
      final firstSchedule = notifier.calls.indexWhere(
        (c) => c.startsWith('schedule:'),
      );
      final retry = notifier.calls.indexOf('cancelAll');
      expect(firstSchedule, 0, reason: 'schedule is the first notifier call');
      expect(retry, greaterThan(firstSchedule));
    });

    test('the drop-to-schedule time is logged from the SDK clock', () async {
      final dropAt = _t0.add(const Duration(minutes: 1));
      notifier.onScheduleHook = () {
        now = dropAt.add(const Duration(milliseconds: 250));
      };
      now = dropAt;
      await controller.onLinkSnapshot(drop(dropAt));
      expect(
        logs.any((l) => l.contains('dropToScheduleMs=250')),
        isTrue,
        reason: logs.join('\n'),
      );
    });
  });
}
