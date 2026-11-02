import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/device/ble_adapter_state.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_packet.dart';
import 'package:flutter/foundation.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/tag_alerts/tag_lease_log.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';
import 'tag_alert_test_support.dart';
import 'tag_battery_test_support.dart';

const _hardware = 'AA:BB:CC:DD:EE:01';
const _five = Duration(minutes: 5);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemorySharedPrefsSdkStore localStore;
  late RecordingTagAlertNotifier notifier;
  late CountingPermissionGateway permissions;
  late FakeDeviceRepository devices;
  late StreamController<BleIncomingEvent> incoming;
  late EixamConnectSdkImpl sdk;
  late DeviceSosController sosController;
  late DateTime clock;
  final disposables = <Future<void> Function()>[];

  EixamConnectSdkImpl build({bool? disarmInBackground}) {
    sosController = DeviceSosController();
    final sos = FakeSosRepository();
    final tracking = FakeTrackingRepository();
    final contacts = FakeContactsRepository();
    final deathMan = FakeDeathManRepository();
    final realtime = FakeRealtimeClient();
    disposables
      ..clear()
      ..addAll([
        sos.dispose,
        tracking.dispose,
        contacts.dispose,
        deathMan.dispose,
        realtime.dispose,
        devices.dispose,
      ]);
    return EixamConnectSdkImpl(
      sosRepository: sos,
      trackingRepository: tracking,
      telemetryRepository: FakeTelemetryRepository(),
      contactsRepository: contacts,
      deviceRepository: devices,
      deviceRegistryRepository: FakeSdkDeviceRegistryRepository(),
      deathManRepository: deathMan,
      permissionsRepository: FakePermissionsRepository(
        permissionState: const PermissionState(
          location: SdkPermissionStatus.denied,
          notifications: SdkPermissionStatus.denied,
          bluetooth: SdkPermissionStatus.denied,
          bluetoothEnabled: true,
        ),
      ),
      notificationsRepository: FakeNotificationsRepository(),
      realtimeClient: realtime,
      deviceSosController: sosController,
      bleIncomingEvents: incoming.stream,
      preferredBleDeviceStore: PreferredBleDeviceStore(localStore: localStore),
      localStore: localStore,
      clock: () => clock,
      tagAlertNotifier: notifier,
      tagAlertPermissions: permissions,
      tagLeaseDisarmsInBackground: disarmInBackground,
      protectionPlatformAdapter: const NoopProtectionPlatformAdapter(),
      backgroundTelemetryPlatformAdapter:
          const NoopBackgroundTelemetryPlatformAdapter(),
    );
  }

  DeviceStatus tag({
    bool connected = true,
    bool paired = true,
    String hardware = _hardware,
    int? nodeId = tagNodeId,
  }) => buildDeviceStatus(
    deviceId: 'ble-id',
    canonicalHardwareId: hardware,
    nodeId: nodeId,
    connected: connected,
    paired: paired,
  );

  Future<void> emit(DeviceStatus status) async {
    devices.emitStatus(status);
    await pumpEventQueue();
  }

  Future<void> background() async {
    sdk.didChangeAppLifecycleState(AppLifecycleState.paused);
    await pumpEventQueue();
  }

  Future<void> foreground() async {
    sdk.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await pumpEventQueue();
  }

  Iterable<String> schedules() =>
      notifier.calls.where((c) => c.startsWith('schedule:'));

  setUp(() async {
    await BleDebugRegistry.instance.resetForLifecycle();
    localStore = MemorySharedPrefsSdkStore();
    notifier = RecordingTagAlertNotifier();
    permissions = CountingPermissionGateway()
      ..next = TagAlertPermissionState.granted;
    incoming = StreamController<BleIncomingEvent>.broadcast();
    clock = DateTime.utc(2026, 11, 2, 12);
    devices = FakeDeviceRepository(initialStatus: tag(connected: false));
    sdk = build();
    await sdk.initialize(
      const EixamSdkConfig(
        apiBaseUrl: 'https://sdk.test',
        deferRuntimeStartup: true,
      ),
    );
    await sdk.setSession(sessionA, deferRuntimeWork: true);
    notifier.calls.clear();
  });

  tearDown(() async {
    await sdk.dispose();
    await incoming.close();
    for (final dispose in disposables) {
      await dispose();
    }
    await BleDebugRegistry.instance.resetForLifecycle();
  });

  test('connecting arms the dead-man alert under the stable key', () async {
    await emit(tag());
    final scheduled = notifier.scheduled.single;
    expect(scheduled.alert.deviceId, _hardware);
    expect(scheduled.alert.kind, TagAlertKind.tagDisconnected);
    expect(scheduled.alert.elapsed, _five);
    expect(scheduled.at, clock.add(_five).add(const Duration(seconds: 75)));
  });

  test('the key never becomes node:<id> when the node id shows up', () async {
    await emit(tag(nodeId: null));
    await emit(tag());
    for (final entry in notifier.scheduled) {
      expect(entry.alert.deviceId, _hardware);
    }
  });

  test('an observed unexpected drop reschedules to exactly drop + X', () async {
    await emit(tag());
    clock = clock.add(const Duration(seconds: 100));
    await emit(tag(connected: false));
    expect(notifier.scheduled.last.at, clock.add(_five));
    // Further ticks while down change nothing.
    final before = notifier.scheduled.length;
    clock = clock.add(const Duration(seconds: 45));
    await background();
    await foreground();
    expect(notifier.scheduled.length, before);
  });

  test('a reconnect removes the alert and re-arms', () async {
    await emit(tag());
    clock = clock.add(const Duration(seconds: 100));
    await emit(tag(connected: false));
    notifier.calls.clear();
    clock = clock.add(const Duration(minutes: 7));
    await emit(tag());
    expect(notifier.calls, [
      'cancel:$_hardware:tagDisconnected',
      'schedule:$_hardware:tagDisconnected',
    ]);
  });

  test(
    'a TAG already away at start is not alerted and nothing is moved',
    () async {
      await emit(tag(connected: false));
      clock = clock.add(const Duration(minutes: 30));
      await background();
      await foreground();
      expect(notifier.calls, isEmpty);
    },
  );

  group('suppression', () {
    test('unpair/manual disconnect never alerts', () async {
      await emit(tag());
      notifier.calls.clear();
      await sdk.unpairDevice();
      await emit(tag(connected: false, paired: false));
      clock = clock.add(const Duration(minutes: 20));
      await background();
      await foreground();
      expect(schedules(), isEmpty);
      expect(
        notifier.calls,
        contains('cancelAllForDevice:$_hardware'),
        reason: 'unpair removes every alert of that TAG',
      );
    });

    test(
      'the provisioning reboot window holds the alert until it ends',
      () async {
        await emit(tag());
        clock = clock.add(const Duration(seconds: 100));
        // The provisioning flow marks the reboot right before writing it.
        sdk.markTagRebootExpectedForTest(const Duration(seconds: 90));
        clock = clock.add(const Duration(seconds: 2));
        notifier.calls.clear();
        await emit(tag(connected: false));
        expect(schedules(), isEmpty, reason: 'expected reboot, no alert');
        expect(notifier.calls, contains('cancel:$_hardware:tagDisconnected'));
        // Back within the window: re-armed, no alert ever.
        clock = clock.add(const Duration(seconds: 30));
        await emit(tag());
        expect(schedules(), hasLength(1));
      },
    );

    test('a reboot that never comes back alerts at hold end + X', () async {
      await emit(tag());
      sdk.markTagRebootExpectedForTest(const Duration(seconds: 90));
      final markedAt = clock;
      clock = clock.add(const Duration(seconds: 2));
      notifier.calls.clear();
      await emit(tag(connected: false));
      expect(schedules(), isEmpty);
      clock = clock.add(const Duration(minutes: 3));
      await background();
      await foreground();
      final holdEnd = markedAt.add(const Duration(seconds: 90));
      expect(notifier.scheduled.last.at, holdEnd.add(_five));
    });

    test('Bluetooth off raises the bluetoothOff kind', () async {
      await emit(tag());
      BleDebugRegistry.instance.update(
        adapterState: BleAdapterState.poweredOff,
      );
      clock = clock.add(const Duration(seconds: 100));
      await emit(tag(connected: false));
      expect(notifier.scheduled.last.alert.kind, TagAlertKind.bluetoothOff);
      expect(notifier.scheduled.last.at, clock.add(_five));
    });

    test('without notification permission nothing is armed', () async {
      permissions.next = TagAlertPermissionState.denied;
      await emit(tag());
      expect(notifier.scheduled, isEmpty);
    });

    test('the "never" setting keeps the lease off', () async {
      await sdk.updateTagAlertSettings(
        TagAlertSettings(deviceId: _hardware, disconnectAfter: null),
      );
      notifier.calls.clear();
      await emit(tag());
      expect(schedules(), isEmpty);
    });
  });

  group('background (lease off by default on every platform)', () {
    Future<void> restart({
      bool? disarm,
      TargetPlatform? platform,
      required DeviceStatus first,
    }) async {
      await sdk.dispose();
      for (final dispose in disposables) {
        await dispose();
      }
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      devices = FakeDeviceRepository(initialStatus: first);
      sdk = build(disarmInBackground: disarm);
      await sdk.initialize(
        const EixamSdkConfig(
          apiBaseUrl: 'https://sdk.test',
          deferRuntimeStartup: true,
        ),
      );
      await sdk.setSession(sessionA, deferRuntimeWork: true);
      notifier.calls.clear();
    }

    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      group('$platform', () {
        test('the lease is dropped on pause and re-armed on resume', () async {
          await restart(platform: platform, first: tag(connected: false));
          await emit(tag());
          notifier.calls.clear();
          await background();
          expect(notifier.calls, contains('cancel:$_hardware:tagDisconnected'));
          notifier.calls.clear();
          clock = clock.add(const Duration(minutes: 20));
          await foreground();
          expect(schedules(), hasLength(1));
        });

        test('backgrounded + connected + no events => nothing scheduled, '
            'no false alert', () async {
          await restart(platform: platform, first: tag(connected: false));
          await emit(tag());
          await background();
          notifier.calls.clear();
          for (var i = 0; i < 20; i++) {
            clock = clock.add(const Duration(minutes: 3));
            await background(); // every wake-up is another snapshot
          }
          expect(schedules(), isEmpty);
          expect(notifier.scheduled.where((e) => e.at.isAfter(clock)), isEmpty);
        });

        test('backgrounded + observed unexpected drop => drop + X', () async {
          await restart(platform: platform, first: tag(connected: false));
          await emit(tag());
          await background();
          clock = clock.add(const Duration(minutes: 2));
          await emit(tag(connected: false));
          expect(notifier.scheduled.last.at, clock.add(_five));
          expect(
            notifier.scheduled.last.alert.kind,
            TagAlertKind.tagDisconnected,
          );
        });

        test('backgrounded + Bluetooth off => the bluetoothOff kind', () async {
          await restart(platform: platform, first: tag(connected: false));
          await emit(tag());
          await background();
          BleDebugRegistry.instance.update(
            adapterState: BleAdapterState.poweredOff,
          );
          clock = clock.add(const Duration(minutes: 1));
          await emit(tag(connected: false));
          expect(notifier.scheduled.last.alert.kind, TagAlertKind.bluetoothOff);
          expect(notifier.scheduled.last.at, clock.add(_five));
        });

        test('backgrounded + SOS active + drop => nothing', () async {
          await restart(platform: platform, first: tag(connected: false));
          await emit(tag());
          await background();
          sosController.handleIncomingSosPacket(
            _activeSosPacket(),
            source: DeviceSosTransitionSource.device,
          );
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await pumpEventQueue();
          expect(
            sosController.currentStatus.state,
            isNot(DeviceSosState.inactive),
          );
          notifier.calls.clear();
          clock = clock.add(const Duration(minutes: 1));
          await emit(tag(connected: false));
          expect(schedules(), isEmpty);
        });

        test('backgrounded + no notification permission => nothing', () async {
          await restart(platform: platform, first: tag(connected: false));
          await emit(tag());
          await background();
          permissions.next = TagAlertPermissionState.denied;
          clock = clock.add(const Duration(minutes: 2)); // past the cache TTL
          notifier.calls.clear();
          await emit(tag(connected: false));
          expect(schedules(), isEmpty);
        });

        test('backgrounded + "never" => nothing', () async {
          await restart(platform: platform, first: tag(connected: false));
          await sdk.updateTagAlertSettings(
            TagAlertSettings(deviceId: _hardware, disconnectAfter: null),
          );
          await emit(tag());
          await background();
          notifier.calls.clear();
          clock = clock.add(const Duration(minutes: 1));
          await emit(tag(connected: false));
          expect(schedules(), isEmpty);
        });

        test('backgrounded + manual disconnect/unpair => nothing', () async {
          await restart(platform: platform, first: tag(connected: false));
          await emit(tag());
          await background();
          notifier.calls.clear();
          await sdk.unpairDevice();
          await emit(tag(connected: false, paired: false));
          expect(schedules(), isEmpty);
        });
      });
    }

    test('a reconnect while backgrounded removes the pending alert', () async {
      await restart(first: tag(connected: false));
      await emit(tag());
      await background();
      clock = clock.add(const Duration(minutes: 1));
      await emit(tag(connected: false));
      notifier.calls.clear();
      clock = clock.add(const Duration(minutes: 2));
      await emit(tag());
      expect(notifier.calls, contains('cancel:$_hardware:tagDisconnected'));
      expect(schedules(), isEmpty, reason: 'still backgrounded: no new lease');
    });

    test(
      'a host may opt out with tagLeaseDisarmsInBackground = false',
      () async {
        await restart(
          disarm: false,
          platform: TargetPlatform.android,
          first: tag(connected: false),
        );
        await emit(tag());
        notifier.calls.clear();
        await background();
        expect(notifier.calls.where((c) => c.startsWith('cancel')), isEmpty);
      },
    );

    test('an app relaunched in the background never arms the lease', () async {
      await sdk.dispose();
      for (final dispose in disposables) {
        await dispose();
      }
      // No lifecycle callback reached the SDK: only the binding knows.
      final binding = TestWidgetsFlutterBinding.instance;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      addTearDown(
        () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
      );
      devices = FakeDeviceRepository(initialStatus: tag(connected: false));
      sdk = build();
      await sdk.initialize(
        const EixamSdkConfig(
          apiBaseUrl: 'https://sdk.test',
          deferRuntimeStartup: true,
        ),
      );
      await sdk.setSession(sessionA, deferRuntimeWork: true);
      notifier.calls.clear();
      await emit(tag());
      expect(schedules(), isEmpty);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      await foreground();
      expect(schedules(), hasLength(1));
    });
  });

  test('a drop seen on a path other than the repository stream still arms '
      '(native-owned status is published the same way)', () async {
    await sdk.dispose();
    for (final dispose in disposables) {
      await dispose();
    }
    final silent = _SilentRefreshRepository(initialStatus: tag());
    devices = silent;
    sdk = build();
    await sdk.initialize(
      const EixamSdkConfig(
        apiBaseUrl: 'https://sdk.test',
        deferRuntimeStartup: true,
      ),
    );
    await sdk.setSession(sessionA, deferRuntimeWork: true);
    await emit(tag());
    notifier.calls.clear();
    clock = clock.add(const Duration(seconds: 100));
    // The repository stream says nothing; a refresh publishes the new state.
    silent.refreshResult = tag(connected: false);
    await sdk.refreshDeviceStatus();
    await pumpEventQueue();
    expect(notifier.scheduled.last.at, clock.add(_five));
  });

  group('debug logs for device tests', () {
    final collected = <String>[];
    setUp(() {
      collected.clear();
      TagLeaseLog.debugSink = collected.add;
    });
    tearDown(() => TagLeaseLog.debugSink = null);
    List<String> leaseLogs() => List<String>.of(collected);

    test('link, drop cause, schedule and cancel are logged without '
        'identifiers or coordinates', () async {
      await emit(tag());
      final sampleAt = clock.subtract(const Duration(seconds: 5));
      incoming.add(
        liveBatchEvent(clock, [
          (timestamp: unixOf(sampleAt), wire: telWire(level: 3)),
        ]),
      );
      await pumpEventQueue();
      clock = clock.add(const Duration(seconds: 100));
      await emit(tag(connected: false));
      clock = clock.add(const Duration(minutes: 7));
      await emit(tag());
      final logs = leaseLogs();
      expect(logs.any((l) => l.contains('link connected=true')), isTrue);
      expect(logs.any((l) => l.contains('lifecycle=')), isTrue);
      expect(
        logs.any((l) => l.contains('drop observed cause=unexpected')),
        isTrue,
      );
      expect(
        logs.any(
          (l) =>
              l.contains('schedule key#') &&
              l.contains('kind=tagDisconnected') &&
              l.contains('fire=2026-11-02T') &&
              l.contains('in='),
        ),
        isTrue,
      );
      expect(logs.any((l) => l.contains('cancel key#')), isTrue);
      final joined = logs.join('\n');
      expect(joined, isNot(contains(_hardware)));
      expect(joined, isNot(contains('Demo Beacon')));
      expect(joined, isNot(contains('Roger')));
      expect(logs.every((l) => l.startsWith('[TAG_LEASE] ')), isTrue);
      // None of it goes to the shared diagnostics ring buffer.
      expect(
        BleDebugRegistry.instance.currentState.events.any(
          (e) => e.message.contains('TAG_LEASE'),
        ),
        isFalse,
      );
      final withoutTimes = joined.replaceAll(
        RegExp(r'\d{4}-\d{2}-\d{2}T[\d:.]+Z'),
        '<time>',
      );
      expect(withoutTimes, isNot(matches(RegExp(r'\d+\.\d{3,}'))));
    });
  });

  test('the alert carries the last position the TAG itself reported', () async {
    await emit(tag());
    final sampleAt = clock.subtract(const Duration(seconds: 5));
    incoming.add(
      liveBatchEvent(clock, [
        (timestamp: unixOf(sampleAt), wire: telWire(level: 3)),
      ]),
    );
    await pumpEventQueue();
    clock = clock.add(const Duration(seconds: 100));
    await emit(tag(connected: false));
    final position = notifier.scheduled.last.alert.lastTagPosition!;
    expect(position.source, SdkLocationSource.connectedDevice);
    expect(position.timestamp, sampleAt);
  });

  test('a device migration re-keys and re-arms under the new key', () async {
    await emit(tag());
    await emit(tag(hardware: 'AA:BB:CC:DD:EE:99'));
    notifier.calls.clear();
    await sdk.rekeyTagAlertDevice(_hardware, 'AA:BB:CC:DD:EE:99');
    await pumpEventQueue();
    expect(notifier.calls, contains('cancelAllForDevice:$_hardware'));
    expect(
      notifier.scheduled.last.alert.deviceId,
      'AA:BB:CC:DD:EE:99',
      reason: 're-armed for the new key',
    );
  });

  test('logout stops the lease; no session means no scheduling', () async {
    await emit(tag());
    await sdk.clearSession();
    notifier.calls.clear();
    await emit(tag());
    expect(schedules(), isEmpty);
  });
}

/// A FakeDeviceRepository whose refresh reports a state the stream never did.
final class _SilentRefreshRepository extends FakeDeviceRepository {
  _SilentRefreshRepository({required super.initialStatus});

  DeviceStatus? refreshResult;

  @override
  Future<DeviceStatus> refreshDeviceStatus() async =>
      refreshResult ?? await getDeviceStatus();
}

EixamSosPacket _activeSosPacket() {
  const flagsWord = 0x8000;
  return EixamSosPacket.tryParse(<int>[
    0x34,
    0x12,
    0x00,
    0x00,
    flagsWord & 0xFF,
    (flagsWord >> 8) & 0xFF,
    0x00,
  ])!;
}
