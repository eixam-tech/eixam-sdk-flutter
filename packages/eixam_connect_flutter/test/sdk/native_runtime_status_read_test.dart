import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/repositories/in_memory_device_repository.dart';
import 'package:eixam_connect_flutter/src/device/ble_device_runtime_provider.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/device/mock_ble_client.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final owner in [
    ProtectionBleOwner.androidService,
    ProtectionBleOwner.iosPlugin,
  ]) {
    test(
      'live runtime status uses $owner after Flutter GATT handoff',
      () async {
        final harness = _Harness();
        addTearDown(harness.dispose);
        await harness.initialize();
        await harness.handoff(owner: owner);
        expect(
          await harness.ble.isConnected(MockBleClient.demoDeviceId),
          isFalse,
        );
        harness.ble.writtenCommands.clear();
        harness.adapter.reply = () =>
            harness.repository.ingestNativeBleNotification(
              payload: harness.ble.runtimeStatusPayload,
              channel: EixamBleChannel.tel,
            );

        final status = await harness.sdk.getDeviceRuntimeStatus();

        expect(status.nodeId, 0x1234);
        expect(status.isProvisioned, isTrue);
        expect(status.batteryPercent, 88);
        expect(harness.adapter.commands.single.bytes, [0x23]);
        expect(harness.ble.writtenCommands, isEmpty);
        expect(
          await harness.ble.isConnected(MockBleClient.demoDeviceId),
          isFalse,
        );
      },
    );
  }

  for (final ready in [false, true]) {
    test(
      'native status rejects ${ready ? 'another target' : 'preparing writer'} without Flutter fallback',
      () async {
        final harness = _Harness();
        addTearDown(harness.dispose);
        await harness.initialize();
        await harness.handoff(
          owner: ProtectionBleOwner.androidService,
          ready: ready,
          target: ready
              ? 'CF:82:00:00:00:02'
              : MockBleClient.demoCanonicalHardwareId,
        );
        harness.ble.writtenCommands.clear();
        await expectLater(
          harness.sdk.getDeviceRuntimeStatus(),
          throwsA(isA<DeviceException>()),
        );
        expect(harness.adapter.commands, isEmpty);
        expect(harness.ble.writtenCommands, isEmpty);
        expect(
          await harness.ble.isConnected(MockBleClient.demoDeviceId),
          isFalse,
        );
      },
    );
  }
}

class _Harness {
  final ble = MockBleClient();
  final adapter = _NativeAdapter();
  late final provider = BleDeviceRuntimeProvider(bleClient: ble);
  late final repository = InMemoryDeviceRepository(runtimeProvider: provider);
  final store = MemorySharedPrefsSdkStore();
  late final sdk = EixamConnectSdkImpl(
    sosRepository: FakeSosRepository(),
    trackingRepository: FakeTrackingRepository(),
    telemetryRepository: FakeTelemetryRepository(),
    contactsRepository: FakeContactsRepository(),
    deviceRepository: repository,
    deviceRegistryRepository: FakeSdkDeviceRegistryRepository(),
    deathManRepository: FakeDeathManRepository(),
    permissionsRepository: FakePermissionsRepository(),
    notificationsRepository: FakeNotificationsRepository(),
    realtimeClient: FakeRealtimeClient(),
    deviceSosController: provider.deviceSosController,
    bleIncomingEvents: provider.watchIncomingEvents(),
    preferredBleDeviceStore: PreferredBleDeviceStore(localStore: store),
    localStore: store,
    protectionPlatformAdapter: adapter,
    backgroundTelemetryPlatformAdapter:
        const NoopBackgroundTelemetryPlatformAdapter(),
  );

  Future<void> initialize() async {
    await ble.initialize();
    await sdk.initialize(
      const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
    );
    BleDebugRegistry.instance.update(
      selectedDeviceId: MockBleClient.demoDeviceId,
    );
    await repository.pairDevice(pairingCode: MockBleClient.demoDeviceId);
    await sdk.setSession(
      const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'user-demo',
        userHash: 'signed-test',
      ),
    );
    await sdk.getDeviceStatus();
  }

  Future<void> handoff({
    required ProtectionBleOwner owner,
    bool ready = true,
    String target = MockBleClient.demoCanonicalHardwareId,
  }) async {
    adapter.snapshot = ProtectionPlatformSnapshot(
      backgroundCapabilityReady: true,
      serviceRunning: true,
      runtimeActive: true,
      runtimeState: ProtectionRuntimeState.active,
      coverageLevel: ProtectionCoverageLevel.full,
      platform: owner == ProtectionBleOwner.androidService
          ? ProtectionPlatform.android
          : ProtectionPlatform.ios,
      bleOwner: owner,
      serviceBleConnected: true,
      serviceBleReady: true,
      nativeCommandServiceReady: ready,
      nativeCommandEa04Ready: ready,
      nativeCommandIdentityReady: true,
      nativeCommandQueueHealthy: true,
      nativeCommandReady: ready,
      protectedDeviceId: target,
      activeDeviceId: target,
    );
    await repository.releaseBleOwnershipToProtectionMode(
      reason: 'test_native_handoff',
    );
    await sdk.rehydrateProtectionState();
    await pumpEventQueue(times: 10);
  }

  Future<void> dispose() async {
    await sdk.dispose();
    await repository.dispose();
    await provider.dispose();
    await ble.dispose();
  }
}

class _NativeAdapter extends NoopProtectionPlatformAdapter {
  ProtectionPlatformSnapshot snapshot = const ProtectionPlatformSnapshot(
    backgroundCapabilityReady: false,
  );
  final commands = <ProtectionPlatformCommandRequest>[];
  Future<void> Function()? reply;

  @override
  ProtectionPlatform get platform => snapshot.platform;
  @override
  Future<ProtectionPlatformSnapshot> getPlatformSnapshot() async => snapshot;
  @override
  Future<ProtectionPlatformCommandResult> sendProtectionCommand({
    required ProtectionPlatformCommandRequest request,
  }) async {
    commands.add(request);
    await reply?.call();
    return const ProtectionPlatformCommandResult(
      success: true,
      route: 'native',
    );
  }
}
