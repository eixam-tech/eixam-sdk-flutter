import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/tag_alerts_controller.dart';
import 'package:eixam_connect_flutter/src/tag_alerts/local_tag_alert_notifier.dart';
import 'package:eixam_connect_flutter/src/tag_alerts/tag_alert_permission_gateway.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_notification_center.dart';
import 'tag_alert_test_support.dart';

const _key = 'AA:BB:CC:DD:EE:01';

/// Records every permission call into the same ordered list as the platform
/// channel, so the order "permission query vs zonedSchedule" can be asserted.
final class _OrderedGateway implements TagAlertPermissionGateway {
  _OrderedGateway(this.order);

  final List<String> order;
  TagAlertPermissionState next = TagAlertPermissionState.granted;

  @override
  Future<TagAlertPermissionState> state() async {
    order.add('permission:state');
    return next;
  }

  @override
  Future<TagAlertPermissionState> request() async {
    order.add('permission:request');
    return next;
  }
}

TagLinkSnapshot up(DateTime at, {bool background = false}) => TagLinkSnapshot(
  deviceKey: _key,
  deviceAlias: 'Roger TAG',
  observedAt: at,
  paired: true,
  connected: true,
  backgroundDisarm: background,
  backgrounded: background,
);

TagLinkSnapshot down(
  DateTime at, {
  bool background = true,
  TagDisconnectCause cause = TagDisconnectCause.unexpected,
}) => TagLinkSnapshot(
  deviceKey: _key,
  observedAt: at,
  paired: true,
  connected: false,
  disconnectedSince: at,
  cause: cause,
  backgroundDisarm: background,
  backgrounded: background,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AndroidFlutterLocalNotificationsPlugin.registerWith();

  late FakeNotificationCenter center;
  late List<String> order;
  late _OrderedGateway gateway;
  late TagAlertsController controller;
  late DateTime now;
  late List<String> logs;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final previous = FlutterLocalNotificationsPlatform.instance;
    FlutterLocalNotificationsPlatform.instance =
        IOSFlutterLocalNotificationsPlugin();
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    center = FakeNotificationCenter();
    order = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) {
      order.add('platform:${call.method}');
      return center.handle(call);
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      FlutterLocalNotificationsPlatform.instance = previous;
      debugDefaultTargetPlatformOverride = null;
    });
    // The plugin validates dates against the real clock.
    now = DateTime.now().toUtc();
    gateway = _OrderedGateway(order);
    logs = <String>[];
    final notifier = LocalTagAlertNotifier(
      plugin: FlutterLocalNotificationsPlugin(),
      ensureInitialized: () async {},
      clock: () => now,
    );
    controller = TagAlertsController(
      store: MemoryTagAlertStore(),
      notifier: notifier,
      permissions: gateway,
      clock: () => now,
      log: logs.add,
    );
    await bind(controller, sessionA);
    order.clear();
  });
  tearDown(() => controller.dispose());

  int indexOf(String entry) => order.indexOf(entry);

  test('a background drop with no cached permission schedules first, with no '
      'permission call before zonedSchedule', () async {
    await controller.onLinkSnapshot(down(now));
    final schedule = indexOf('platform:zonedSchedule');
    expect(schedule, isNonNegative);
    expect(order.sublist(0, schedule), isNot(contains('permission:state')));
    expect(order.sublist(0, schedule), isNot(contains('permission:request')));
    expect(center.pending, hasLength(1));
    // The answer is brought up to date afterwards, without blocking.
    await pumpEventQueue();
    expect(order.skip(schedule), contains('permission:state'));
  });

  test('a cached "granted" is used as is: no permission call precedes the '
      'schedule, even when the cache is old', () async {
    await controller.onLinkSnapshot(up(now)); // foreground: queries once
    expect(order.where((e) => e == 'permission:state'), hasLength(1));
    order.clear();
    center.pending.clear();
    now = now.add(const Duration(hours: 3)); // far past the 60 s TTL
    await controller.onLinkSnapshot(down(now));
    final schedule = indexOf('platform:zonedSchedule');
    expect(schedule, isNonNegative);
    expect(order.sublist(0, schedule), isNot(contains('permission:state')));
    expect(center.pending, hasLength(1));
  });

  test('Bluetooth off follows the same path', () async {
    await controller.onLinkSnapshot(
      down(now, cause: TagDisconnectCause.bluetoothOff),
    );
    final schedule = indexOf('platform:zonedSchedule');
    expect(schedule, isNonNegative);
    expect(order.sublist(0, schedule), isNot(contains('permission:state')));
  });

  test('the alert is scheduled for exactly drop + X', () async {
    final dropAt = now;
    await controller.onLinkSnapshot(down(dropAt));
    expect(logs.any((l) => l.contains('kind=tagDisconnected')), isTrue);
    expect(center.pending, hasLength(1));
  });

  test('a cached "denied" schedules nothing; if the refresh finds it granted '
      'the alert is scheduled right after, at drop + X', () async {
    gateway.next = TagAlertPermissionState.denied;
    await controller.onLinkSnapshot(up(now)); // caches "denied", no lease
    expect(center.pending, isEmpty);
    order.clear();
    // The user granted permission in Settings while the app was away.
    gateway.next = TagAlertPermissionState.granted;
    final dropAt = now.add(const Duration(minutes: 1));
    now = dropAt;
    await controller.onLinkSnapshot(down(dropAt));
    // Nothing was scheduled on the stale "no"; the refresh runs after it.
    expect(center.pending, isEmpty, reason: 'not scheduled on a stale "no"');
    await pumpEventQueue();
    await pumpEventQueue();
    expect(center.pending, hasLength(1), reason: 're-evaluated after refresh');
    expect(
      logs.any((l) => l.contains('schedule key#') && l.contains('in=')),
      isTrue,
    );
  });

  test(
    'the foreground drop path still queries the permission (cached 60 s)',
    () async {
      await controller.onLinkSnapshot(down(now, background: false));
      final schedule = indexOf('platform:zonedSchedule');
      expect(schedule, isNonNegative);
      expect(order.sublist(0, schedule), contains('permission:state'));
    },
  );

  test(
    'the elapsed time from drop observed to schedule done is logged',
    () async {
      final dropAt = now;
      await controller.onLinkSnapshot(down(dropAt));
      final line = logs.firstWhere((l) => l.contains('dropToScheduleMs='));
      expect(line, contains('scheduled key#'));
      expect(line, contains('kind=tagDisconnected'));
      final ms = int.parse(
        RegExp(r'dropToScheduleMs=(-?\d+)').firstMatch(line)![1]!,
      );
      expect(ms, greaterThanOrEqualTo(0));
      expect(ms, lessThan(5000));
    },
  );
}
