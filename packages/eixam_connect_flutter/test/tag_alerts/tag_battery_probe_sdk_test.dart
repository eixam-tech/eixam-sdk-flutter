import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/repositories/in_memory_device_repository.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_device_runtime_provider.dart';
import 'package:eixam_connect_flutter/src/device/ble_scan_result.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/device/mock_ble_client.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';
import 'tag_alert_test_support.dart';
import 'tag_battery_test_support.dart';

/// Counts every BLE entry point a reconnect, rebind or rediscovery would use.
final class _CountingBleClient extends MockBleClient {
  int scans = 0;
  int connects = 0;
  int disconnects = 0;

  @override
  Future<List<BleScanResult>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) {
    scans++;
    return super.scan(timeout: timeout);
  }

  @override
  Future<void> connect(String deviceId) {
    connects++;
    return super.connect(deviceId);
  }

  @override
  Future<void> disconnect(String deviceId) {
    disconnects++;
    return super.disconnect(deviceId);
  }
}

/// A real [InMemoryDeviceRepository] whose readiness and status the test
/// controls, and which records every entry point the old probe path
/// (`getDeviceRuntimeStatus()` -> command-capable helper -> auto-connect ->
/// identity snapshot) would have used to reconnect or rebind.
final class _SpyRepository extends InMemoryDeviceRepository {
  _SpyRepository({required super.runtimeProvider, required super.localStore})
    : super(heartbeatInterval: const Duration(hours: 1));

  // Closed in the test tearDown.
  // ignore: close_sinks
  final StreamController<DeviceStatus> statuses =
      StreamController<DeviceStatus>.broadcast();
  DeviceStatus status = buildDeviceStatus(
    deviceId: 'ble-id',
    canonicalHardwareId: 'AA:BB:CC:DD:EE:01',
    nodeId: tagNodeId,
  );
  bool commandReady = true;
  int statusRequests = 0;
  int reconnects = 0;
  int identitySnapshots = 0;
  int pairs = 0;
  int refreshes = 0;

  @override
  Stream<DeviceStatus> watchDeviceStatus() => statuses.stream;

  @override
  Future<DeviceStatus> getDeviceStatus() async => status;

  @override
  bool get hasCommandCapableBleRuntime => commandReady;

  @override
  Future<DeviceRuntimeStatus> getDeviceRuntimeStatus({
    Future<void> Function(EixamDeviceCommand command)? commandSender,
  }) async {
    statusRequests++;
    return runtimeStatus(percent: 20);
  }

  @override
  Future<DeviceStatus> reconnectDevice({
    required PreferredDevice device,
    String? attemptId,
    bool Function()? canCreateGatt,
  }) {
    reconnects++;
    return super.reconnectDevice(
      device: device,
      attemptId: attemptId,
      canCreateGatt: canCreateGatt,
    );
  }

  @override
  Future<RuntimeIdentitySnapshot> getRuntimeIdentitySnapshot() {
    identitySnapshots++;
    return super.getRuntimeIdentitySnapshot();
  }

  @override
  Future<DeviceStatus> pairDevice({required String pairingCode}) {
    pairs++;
    return super.pairDevice(pairingCode: pairingCode);
  }

  @override
  Future<DeviceStatus> refreshDeviceStatus() {
    refreshes++;
    return super.refreshDeviceStatus();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CountingBleClient ble;
  late BleDeviceRuntimeProvider provider;
  late _SpyRepository repository;
  late EixamConnectSdkImpl sdk;
  late RecordingTagAlertNotifier notifier;
  late CountingPermissionGateway permissions;
  late MemorySharedPrefsSdkStore store;

  setUp(() async {
    await BleDebugRegistry.instance.resetForLifecycle();
    store = MemorySharedPrefsSdkStore();
    ble = _CountingBleClient();
    provider = BleDeviceRuntimeProvider(bleClient: ble);
    repository = _SpyRepository(runtimeProvider: provider, localStore: store);
    notifier = RecordingTagAlertNotifier();
    permissions = CountingPermissionGateway()
      ..next = TagAlertPermissionState.granted;
    sdk = EixamConnectSdkImpl(
      sosRepository: FakeSosRepository(),
      trackingRepository: FakeTrackingRepository(),
      telemetryRepository: FakeTelemetryRepository(),
      contactsRepository: FakeContactsRepository(),
      deviceRepository: repository,
      deviceRegistryRepository: FakeSdkDeviceRegistryRepository(),
      deathManRepository: FakeDeathManRepository(),
      permissionsRepository: FakePermissionsRepository(
        permissionState: const PermissionState(
          location: SdkPermissionStatus.denied,
          notifications: SdkPermissionStatus.denied,
          bluetooth: SdkPermissionStatus.denied,
          bluetoothEnabled: true,
        ),
      ),
      notificationsRepository: FakeNotificationsRepository(),
      realtimeClient: FakeRealtimeClient(),
      deviceSosController: provider.deviceSosController,
      bleIncomingEvents: provider.watchIncomingEvents(),
      preferredBleDeviceStore: PreferredBleDeviceStore(localStore: store),
      localStore: store,
      tagAlertNotifier: notifier,
      tagAlertPermissions: permissions,
      protectionPlatformAdapter: const NoopProtectionPlatformAdapter(),
      backgroundTelemetryPlatformAdapter:
          const NoopBackgroundTelemetryPlatformAdapter(),
    );
    await sdk.initialize(
      const EixamSdkConfig(
        apiBaseUrl: 'https://sdk.test',
        deferRuntimeStartup: true,
      ),
    );
    await sdk.setSession(sessionA, deferRuntimeWork: true);
    repository.statuses.add(repository.status);
    await pumpEventQueue();
  });

  tearDown(() async {
    await sdk.dispose();
    await repository.statuses.close();
    await provider.dispose();
    await ble.dispose();
    await BleDebugRegistry.instance.resetForLifecycle();
  });

  Future<void> backgroundAndResume() async {
    sdk.didChangeAppLifecycleState(AppLifecycleState.paused);
    sdk.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await pumpEventQueue();
  }

  test('control: with a ready command path the probe sends one 0x23', () async {
    repository.commandReady = true;
    await backgroundAndResume();
    expect(repository.statusRequests, 1);
  });

  test('M2: with no ready command path the probe sends nothing and never '
      'reconnects, rebinds, scans or re-pairs', () async {
    repository.commandReady = false;
    final scans = ble.scans;
    final connects = ble.connects;
    final disconnects = ble.disconnects;
    final identity = repository.identitySnapshots;
    final reconnects = repository.reconnects;

    await backgroundAndResume();

    expect(
      repository.statusRequests,
      0,
      reason: 'no 0x23 without a ready path',
    );
    expect(repository.reconnects, reconnects, reason: 'no reconnect');
    expect(repository.identitySnapshots, identity, reason: 'no rebind check');
    expect(repository.pairs, 0);
    expect(ble.scans, scans, reason: 'no rediscovery');
    expect(ble.connects, connects, reason: 'no GATT connect');
    expect(ble.disconnects, disconnects, reason: 'no GATT teardown');
  });

  test('a TAG switched while the reply was pending is never credited', () async {
    repository.commandReady = true;
    // The reply arrives after the status moved to another TAG.
    // (Simulated by switching the status before the awaited reply resolves.)
    repository.status = buildDeviceStatus(
      deviceId: 'other-ble-id',
      canonicalHardwareId: 'AA:BB:CC:DD:EE:99',
      nodeId: 99,
    );
    repository.statuses.add(repository.status);
    await pumpEventQueue();
    await backgroundAndResume();
    // Probe ran for the *current* TAG (other-ble-id, node 99); the reply's node
    // does not match, so no reading may be submitted.
    expect(notifier.shown, isEmpty);
    expect(repository.statusRequests, 1);
  });
}
