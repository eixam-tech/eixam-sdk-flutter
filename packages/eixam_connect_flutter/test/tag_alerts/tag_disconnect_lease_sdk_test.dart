import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/device/ble_adapter_state.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
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
  late DateTime clock;
  final disposables = <Future<void> Function()>[];

  EixamConnectSdkImpl build({bool? disarmInBackground}) {
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
      deviceSosController: DeviceSosController(),
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

  group('background', () {
    test('iOS: the lease is dropped on pause and re-armed on resume', () async {
      await sdk.dispose();
      for (final dispose in disposables) {
        await dispose();
      }
      devices = FakeDeviceRepository(initialStatus: tag(connected: false));
      sdk = build(disarmInBackground: true);
      await sdk.initialize(
        const EixamSdkConfig(
          apiBaseUrl: 'https://sdk.test',
          deferRuntimeStartup: true,
        ),
      );
      await sdk.setSession(sessionA, deferRuntimeWork: true);
      await emit(tag());
      notifier.calls.clear();
      await background();
      expect(notifier.calls, contains('cancel:$_hardware:tagDisconnected'));
      notifier.calls.clear();
      clock = clock.add(const Duration(minutes: 20));
      await foreground();
      expect(schedules(), hasLength(1));
    });

    test('a disconnect woken in the background still arms exactly', () async {
      await sdk.dispose();
      for (final dispose in disposables) {
        await dispose();
      }
      devices = FakeDeviceRepository(initialStatus: tag(connected: false));
      sdk = build(disarmInBackground: true);
      await sdk.initialize(
        const EixamSdkConfig(
          apiBaseUrl: 'https://sdk.test',
          deferRuntimeStartup: true,
        ),
      );
      await sdk.setSession(sessionA, deferRuntimeWork: true);
      await emit(tag());
      await background();
      clock = clock.add(const Duration(minutes: 2));
      await emit(tag(connected: false));
      expect(notifier.scheduled.last.at, clock.add(_five));
    });

    test(
      'an app relaunched in the background never arms the lease (iOS)',
      () async {
        await sdk.dispose();
        for (final dispose in disposables) {
          await dispose();
        }
        // No lifecycle callback reached the SDK: only the binding knows.
        final binding = TestWidgetsFlutterBinding.instance;
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        addTearDown(
          () =>
              binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
        );
        devices = FakeDeviceRepository(initialStatus: tag(connected: false));
        sdk = build(disarmInBackground: true);
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
      },
    );

    test('Android keeps the lease armed in the background', () async {
      await sdk.dispose();
      for (final dispose in disposables) {
        await dispose();
      }
      devices = FakeDeviceRepository(initialStatus: tag(connected: false));
      sdk = build(disarmInBackground: false);
      await sdk.initialize(
        const EixamSdkConfig(
          apiBaseUrl: 'https://sdk.test',
          deferRuntimeStartup: true,
        ),
      );
      await sdk.setSession(sessionA, deferRuntimeWork: true);
      await emit(tag());
      notifier.calls.clear();
      await background();
      expect(notifier.calls.where((c) => c.startsWith('cancel')), isEmpty);
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
