import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/repositories/local_notifications_repository.dart';
import 'package:eixam_connect_flutter/src/tag_alerts/local_tag_alert_notifier.dart';
import 'package:eixam_connect_flutter/src/tag_alerts/tag_alert_notification_ids.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_notification_center.dart';
import 'tag_alert_test_support.dart';
import 'package:eixam_connect_flutter/src/sdk/tag_alerts_controller.dart';

TagAlert disconnected(String device, {int minutes = 5, String? alias}) =>
    TagAlert(
      kind: TagAlertKind.tagDisconnected,
      deviceId: device,
      deviceAlias: alias,
      elapsed: Duration(minutes: minutes),
    );

TagAlert battery(String device, [TagAlertBatteryThreshold? t]) => TagAlert(
  kind: TagAlertKind.batteryLow,
  deviceId: device,
  batteryThreshold: t ?? TagAlertBatteryThreshold.below30,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AndroidFlutterLocalNotificationsPlugin.registerWith();

  late FakeNotificationCenter center;
  late LocalTagAlertNotifier notifier;
  late int initCalls;
  late DateTime now;
  late FlutterLocalNotificationsPlugin plugin;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final previous = FlutterLocalNotificationsPlatform.instance;
    FlutterLocalNotificationsPlatform.instance =
        IOSFlutterLocalNotificationsPlugin();
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    center = FakeNotificationCenter();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, center.handle);
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      FlutterLocalNotificationsPlatform.instance = previous;
      debugDefaultTargetPlatformOverride = null;
    });
    initCalls = 0;
    // The plugin validates scheduled dates against the real clock, so a fixed
    // date would turn into a time bomb once it passes.
    now = DateTime.now().toUtc();
    plugin = FlutterLocalNotificationsPlugin();
    notifier = LocalTagAlertNotifier(
      plugin: plugin,
      ensureInitialized: () async => initCalls++,
      clock: () => now,
    );
  });

  DateTime inMinutes(int m) => now.add(Duration(minutes: m));

  group('ids and payload', () {
    test('the reserved range avoids every id known to be in use', () {
      const known = <int>[
        6021, 6022, 6023, 6024, 6031, //
        41001, 41002, //
        42001, 42002, 42003, 42004, 42005, 42006, 42007, 42008, //
        43000, 44001,
      ];
      for (final id in known) {
        expect(TagAlertNotificationIds.contains(id), isFalse, reason: '$id');
      }
      expect(TagAlertNotificationIds.rangeEnd, lessThan(2147483647));
    });

    test('generic ids are moved out of the reserved range', () {
      for (final id in <int>[
        0,
        999999999,
        TagAlertNotificationIds.rangeStart,
        TagAlertNotificationIds.rangeEnd,
        TagAlertNotificationIds.rangeEnd + 1,
        2147483646,
      ]) {
        expect(
          TagAlertNotificationIds.contains(
            TagAlertNotificationIds.outsideRange(id),
          ),
          isFalse,
          reason: '$id',
        );
      }
      expect(TagAlertNotificationIds.outsideRange(42001), 42001);
    });

    test('candidates are deterministic and always inside the range', () {
      for (var i = 0; i < 500; i++) {
        for (final kind in TagAlertKind.values) {
          final id = TagAlertNotificationIds.candidate('device-$i', kind);
          expect(TagAlertNotificationIds.contains(id), isTrue);
          expect(id, TagAlertNotificationIds.candidate('device-$i', kind));
        }
      }
    });

    test('payload round-trips arbitrary keys and never contains "sos"', () {
      for (final key in <String>[
        'AA:BB:CC:DD:EE:FF',
        'node:42',
        'sos-device',
        'SOS',
        'presos:pre-sos',
        'ñandú 🛰',
        'a:b:c',
      ]) {
        for (final kind in TagAlertKind.values) {
          final payload = TagAlertPayload.encode(key, kind);
          expect(payload, startsWith('tag_alert:'));
          expect(payload.toLowerCase(), isNot(contains('sos')));
          expect(
            TagAlertPayload.decode(payload),
            TagAlertSlot(key, kind),
            reason: key,
          );
        }
      }
      expect(TagAlertPayload.channelId.toLowerCase(), isNot(contains('sos')));
    });

    test('decode ignores foreign and malformed payloads', () {
      for (final payload in <String?>[
        null,
        '',
        'sos:1',
        'tag_alert:',
        'tag_alert:battery_low',
        'tag_alert:unknown:6162',
        'tag_alert:battery_low:zz',
        'tag_alert:battery_low:616',
        'tag_alert:battery_low:61:62',
      ]) {
        expect(TagAlertPayload.decode(payload), isNull, reason: '$payload');
      }
    });
  });

  group('schedule', () {
    test(
      'creates one pending alert with a reserved id and tag payload',
      () async {
        await notifier.schedule(disconnected('tag-1'), inMinutes(5));
        expect(center.pending, hasLength(1));
        final entry = center.pending.values.single;
        expect(TagAlertNotificationIds.contains(entry['id']! as int), isTrue);
        expect(
          TagAlertPayload.decode(entry['payload']! as String),
          const TagAlertSlot('tag-1', TagAlertKind.tagDisconnected),
        );
        expect(center.delivered, isEmpty);
        expect(initCalls, 1);
      },
    );

    test('is idempotent and a reschedule replaces in place', () async {
      await notifier.schedule(disconnected('tag-1'), inMinutes(5));
      final firstId = center.pending.keys.single;
      final firstWhen = center.pending[firstId]!['scheduledDateTime'];
      await notifier.schedule(disconnected('tag-1'), inMinutes(5));
      expect(center.pending.keys.single, firstId);
      await notifier.schedule(disconnected('tag-1'), inMinutes(20));
      expect(center.pending.keys.single, firstId);
      expect(center.pending[firstId]!['scheduledDateTime'], isNot(firstWhen));
      expect(center.pending, hasLength(1));
    });

    test('many rapid reschedules (a lease) leave exactly one alert', () async {
      await Future.wait([
        for (var i = 1; i <= 60; i++)
          notifier.schedule(disconnected('tag-1'), inMinutes(i)),
      ]);
      expect(center.pending, hasLength(1));
      expect(center.delivered, isEmpty);
    });

    test('slots are independent per device and kind', () async {
      await notifier.schedule(disconnected('tag-1'), inMinutes(5));
      await notifier.schedule(disconnected('tag-2'), inMinutes(5));
      await notifier.schedule(battery('tag-1'), inMinutes(5));
      expect(center.pending.keys.toSet(), hasLength(3));
    });

    test('colliding candidates are probed apart and stay stable', () async {
      final byCandidate = <int, String>{};
      String? first;
      String? second;
      for (var i = 0; i < 200000 && second == null; i++) {
        final key = 'device-$i';
        final id = TagAlertNotificationIds.candidate(
          key,
          TagAlertKind.tagDisconnected,
        );
        final other = byCandidate[id];
        if (other != null) {
          first = other;
          second = key;
        } else {
          byCandidate[id] = key;
        }
      }
      expect(second, isNotNull, reason: 'birthday collision must exist');
      await notifier.schedule(disconnected(first!), inMinutes(5));
      await notifier.schedule(disconnected(second!), inMinutes(5));
      expect(center.pending, hasLength(2));
      final idFirst = center.pending.entries
          .firstWhere(
            (e) =>
                e.value['payload'] ==
                TagAlertPayload.encode(first!, TagAlertKind.tagDisconnected),
          )
          .key;
      // Rescheduling either keeps its own id; cancelling one keeps the other.
      await notifier.schedule(disconnected(second), inMinutes(9));
      await notifier.schedule(disconnected(first), inMinutes(9));
      expect(center.pending, hasLength(2));
      expect(center.pending.containsKey(idFirst), isTrue);
      await notifier.cancel(first, TagAlertKind.tagDisconnected);
      expect(center.pending, hasLength(1));
      expect(
        TagAlertPayload.decode(
          center.pending.values.single['payload'] as String,
        ),
        TagAlertSlot(second, TagAlertKind.tagDisconnected),
      );
    });

    test(
      'an id inside the range held by someone else is never reused',
      () async {
        final candidate = TagAlertNotificationIds.candidate(
          'tag-1',
          TagAlertKind.tagDisconnected,
        );
        center.pending[candidate] = {'id': candidate, 'payload': 'sos:foreign'};
        await notifier.schedule(disconnected('tag-1'), inMinutes(5));
        expect(center.pending[candidate]!['payload'], 'sos:foreign');
        expect(center.pending, hasLength(2));
      },
    );

    test('a moment in the past is delivered now instead of dropped', () async {
      await notifier.schedule(
        disconnected('tag-1'),
        now.subtract(const Duration(minutes: 1)),
      );
      expect(center.pending, isEmpty);
      expect(center.delivered, hasLength(1));
    });

    test(
      'text comes from the resolver; a faulty resolver falls back',
      () async {
        final custom = LocalTagAlertNotifier(
          plugin: plugin,
          ensureInitialized: () async {},
          clock: () => now,
          textResolver: (alert) =>
              TagAlertText(title: 'T-${alert.kind.name}', body: 'B'),
        );
        await custom.schedule(disconnected('tag-1'), inMinutes(5));
        expect(center.pending.values.single['title'], 'T-tagDisconnected');
        center.pending.clear();
        final broken = LocalTagAlertNotifier(
          plugin: plugin,
          ensureInitialized: () async {},
          clock: () => now,
          textResolver: (_) => throw StateError('boom'),
        );
        await broken.schedule(
          disconnected('tag-1', alias: 'Roger TAG'),
          inMinutes(5),
        );
        expect(center.pending.values.single['title'], 'TAG disconnected');
        center.pending.clear();
        final empty = LocalTagAlertNotifier(
          plugin: plugin,
          ensureInitialized: () async {},
          clock: () => now,
          textResolver: (_) => const TagAlertText(title: ' ', body: ''),
        );
        await empty.schedule(disconnected('tag-1'), inMinutes(5));
        expect(center.pending.values.single['title'], 'TAG disconnected');
      },
    );
  });

  group('slot id cache (lease fast path)', () {
    test(
      'the first push costs three platform calls, later pushes one',
      () async {
        var calls = 0;
        const channel = MethodChannel(
          'dexterous.com/flutter/local_notifications',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) {
          calls++;
          return center.handle(call);
        });
        await notifier.schedule(disconnected('tag-1'), inMinutes(5));
        expect(calls, 3, reason: 'pending + active listing + zonedSchedule');
        calls = 0;
        for (var i = 1; i <= 20; i++) {
          await notifier.schedule(disconnected('tag-1'), inMinutes(5 + i));
        }
        expect(calls, 20, reason: 'one zonedSchedule per push');
        expect(center.pending, hasLength(1));
      },
    );

    test('a cancel drops the cache; the next push resolves again', () async {
      await notifier.schedule(disconnected('tag-1'), inMinutes(5));
      final id = center.pending.keys.single;
      await notifier.cancel('tag-1', TagAlertKind.tagDisconnected);
      expect(center.pending, isEmpty);
      await notifier.schedule(disconnected('tag-1'), inMinutes(5));
      expect(center.pending.keys.single, id);
    });

    test('a cached id is never taken by another slot', () async {
      final byCandidate = <int, String>{};
      String? first;
      String? second;
      for (var i = 0; i < 200000 && second == null; i++) {
        final key = 'device-$i';
        final id = TagAlertNotificationIds.candidate(
          key,
          TagAlertKind.tagDisconnected,
        );
        final other = byCandidate[id];
        if (other != null) {
          first = other;
          second = key;
        } else {
          byCandidate[id] = key;
        }
      }
      expect(second, isNotNull);
      await notifier.schedule(disconnected(first!), inMinutes(5));
      final firstId = center.pending.keys.single;
      // The first slot's alert fired and was dismissed: nothing is pending.
      center.pending.clear();
      await notifier.schedule(disconnected(second!), inMinutes(5));
      expect(center.pending.keys.single, isNot(firstId));
      // The first slot's fast push must not overwrite the second slot's alert.
      await notifier.schedule(disconnected(first), inMinutes(9));
      expect(center.pending, hasLength(2));
      expect(center.pending.containsKey(firstId), isTrue);
    });

    test(
      'cancelAll and cancelAllForDevice clear only what they remove',
      () async {
        await notifier.schedule(disconnected('tag-1'), inMinutes(5));
        await notifier.schedule(disconnected('tag-2'), inMinutes(5));
        await notifier.cancelAllForDevice('tag-1');
        expect(center.pending, hasLength(1));
        await notifier.schedule(disconnected('tag-2'), inMinutes(9));
        expect(center.pending, hasLength(1));
        await notifier.cancelAll();
        expect(center.pending, isEmpty);
      },
    );
  });

  group('show', () {
    test('delivers one alert per slot and clears a pending twin', () async {
      await notifier.schedule(battery('tag-1'), inMinutes(5));
      await notifier.show(battery('tag-1', TagAlertBatteryThreshold.below10));
      expect(center.pending, isEmpty);
      expect(center.delivered, hasLength(1));
      await notifier.show(battery('tag-1'));
      expect(center.delivered, hasLength(1));
    });
  });

  group('cancel paths', () {
    Future<void> populate() async {
      await notifier.schedule(disconnected('tag-1'), inMinutes(5));
      await notifier.show(battery('tag-1'));
      await notifier.schedule(disconnected('tag-2'), inMinutes(5));
      await notifier.show(battery('tag-2'));
      center.seedSos();
    }

    test('cancel removes the slot, scheduled or delivered, only', () async {
      await populate();
      await notifier.cancel('tag-1', TagAlertKind.batteryLow);
      expect(
        center.delivered.values.where(
          (e) =>
              TagAlertPayload.decode(e['payload'] as String?)?.deviceKey ==
              'tag-1',
        ),
        isEmpty,
      );
      expect(center.tagIds, hasLength(3));
      await notifier.cancel('tag-1', TagAlertKind.tagDisconnected);
      expect(center.tagIds, hasLength(2));
      expect(center.sosIntact(), isTrue);
    });

    test('cancelAllForDevice removes scheduled and delivered alerts of that '
        'device only (alias privacy on unpair)', () async {
      await populate();
      await notifier.cancelAllForDevice('tag-1');
      final left = [...center.pending.values, ...center.delivered.values]
          .map((e) => TagAlertPayload.decode(e['payload'] as String?))
          .whereType<TagAlertSlot>();
      expect(left.map((s) => s.deviceKey).toSet(), {'tag-2'});
      expect(center.sosIntact(), isTrue);
    });

    test('cancelAll removes every tag alert and nothing else', () async {
      await populate();
      await notifier.cancelAll();
      expect(center.tagIds, isEmpty);
      expect(
        center.pending.keys.toSet().union(center.delivered.keys.toSet()),
        center.sosIds,
      );
    });

    test('cancel paths never initialize the plugin', () async {
      await populate();
      final before = initCalls;
      await notifier.cancel('tag-1', TagAlertKind.batteryLow);
      await notifier.cancelAllForDevice('tag-2');
      await notifier.cancelAll();
      expect(initCalls, before);
    });
  });

  group('SOS isolation', () {
    test(
      'schedule, show and every cancel never touch SOS notifications',
      () async {
        center.seedSos();
        final sosSnapshot = {
          for (final e in {...center.pending, ...center.delivered}.entries)
            e.key: e.value['payload'],
        };
        await notifier.schedule(disconnected('tag-1'), inMinutes(5));
        await notifier.schedule(disconnected('tag-1'), inMinutes(9));
        await notifier.show(battery('tag-1'));
        await notifier.cancel('tag-1', TagAlertKind.tagDisconnected);
        await notifier.cancelAllForDevice('tag-1');
        await notifier.cancelAll();
        expect(center.sosIntact(), isTrue);
        final after = {
          for (final e in {...center.pending, ...center.delivered}.entries)
            e.key: e.value['payload'],
        };
        expect(after, sosSnapshot);
        // And nothing the notifier issued targeted a non-reserved id.
        final touched = center.log
            .map((l) => int.parse(l.split(':').last))
            .toSet();
        expect(touched.every(TagAlertNotificationIds.contains), isTrue);
      },
    );

    test('clearSosNotifications leaves tag alerts alone, even for hostile '
        'device keys', () async {
      await notifier.schedule(disconnected('sos-device'), inMinutes(5));
      await notifier.show(battery('pre-sos:SOS'));
      center.seedSos();
      final repository = LocalNotificationsRepository(plugin: plugin);
      await repository.clearSosNotifications();
      expect(center.tagIds, hasLength(2));
      // The SOS repository still clears real SOS notifications.
      expect(center.pending.containsKey(42001), isFalse);
      expect(center.delivered.containsKey(42002), isFalse);
    });
  });

  test(
    'SOS notification delivery is unchanged by the tag alert foundation',
    () async {
      final repository = LocalNotificationsRepository(plugin: plugin);
      await repository.showLocalNotification(
        notificationId: 42001,
        title: 'SOS',
        body: 'body',
        payload: 'sos:incident-9',
      );
      // Explicit ids are honoured exactly; the SOS payload is still recognised.
      expect(center.delivered.keys, [42001]);
      expect(center.delivered[42001]!['payload'], 'sos:incident-9');
      // Auto ids are produced outside the reserved range.
      await repository.showLocalNotification(
        title: 'x',
        body: 'y',
        payload: 'sos:incident-9',
      );
      expect(
        center.delivered.keys.where(TagAlertNotificationIds.contains),
        isEmpty,
      );
      await repository.clearSosNotifications();
      expect(center.delivered, isEmpty);
    },
  );

  test('m3: under host-managed notifications an uninitialised plugin does '
      'not consume the low-battery alert', () async {
    // hostAppManaged: the SDK never initialises the shared plugin; the host
    // does it lazily, possibly after the first battery alert.
    final hostManaged = LocalTagAlertNotifier(
      plugin: plugin,
      ensureInitialized: () async {},
      clock: () => now,
    );
    final store = MemoryTagAlertStore();
    final controller = TagAlertsController(store: store, notifier: hostManaged);
    addTearDown(controller.dispose);
    await bind(controller, sessionA);
    center.rejectUntilInitialized = true;
    final errors = <Object>[];
    final sub = controller
        .watchTagAlertSettings('tag-1')
        .listen((_) {}, onError: errors.add);
    var n = 0;
    Future<void> reading() => controller.onBatteryReading(
      deviceKey: 'tag-1',
      band: TagBatteryBand.below30,
      sourceKey: 's${n++}',
      epoch: 1,
    );

    await reading();
    await reading();
    await pumpEventQueue();
    expect(errors, isNotEmpty, reason: 'the failure is surfaced');
    expect(center.delivered, isEmpty);
    expect(store.raw, isNot(contains('"cycles"')), reason: 'not consumed');

    // The host initialises the plugin; the next live reading delivers it.
    center.rejectUntilInitialized = false;
    await reading();
    expect(center.delivered, hasLength(1));
    expect(
      TagAlertPayload.decode(
        center.delivered.values.single['payload'] as String,
      ),
      const TagAlertSlot('tag-1', TagAlertKind.batteryLow),
    );
    expect(store.raw, contains('"cycles"'));
    await reading();
    expect(center.delivered, hasLength(1));
    await sub.cancel();
  });

  test('ensureInitialized runs before show and schedule', () async {
    await notifier.show(battery('tag-1'));
    await notifier.schedule(disconnected('tag-1'), inMinutes(5));
    expect(initCalls, 2);
  });
}
