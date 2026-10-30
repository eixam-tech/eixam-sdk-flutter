import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/repositories/in_memory_device_repository.dart';
import 'package:eixam_connect_flutter/src/device/ble_device_runtime_provider.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/preferred_ble_device.dart';
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

  for (final owner in [
    ProtectionBleOwner.androidService,
    ProtectionBleOwner.iosPlugin,
  ]) {
    test(
      'exit drains pending $owner release and reclaims the same TAG without restart',
      () async {
        final harness = _Harness();
        addTearDown(harness.dispose);
        await harness.initialize();
        await PreferredBleDeviceStore(
          localStore: harness.store,
        ).savePreferredDevice(
          PreferredBleDevice(
            deviceId: MockBleClient.demoDeviceId,
            displayName: 'EIXAM Demo',
            lastConnectedAt: DateTime.now(),
          ),
        );
        final release = Completer<void>();
        harness.repository.releaseBarrier = release;
        harness.adapter.snapshot = ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platform: owner == ProtectionBleOwner.androidService
              ? ProtectionPlatform.android
              : ProtectionPlatform.ios,
          serviceRunning: true,
          runtimeActive: true,
          runtimeState: ProtectionRuntimeState.active,
          coverageLevel: ProtectionCoverageLevel.partial,
          bleOwner: owner,
          activeDeviceId: MockBleClient.demoDeviceId,
          protectedDeviceId: MockBleClient.demoDeviceId,
        );
        final handoff = harness.sdk.rehydrateProtectionState();
        await harness.repository.releaseStarted.future.timeout(
          const Duration(seconds: 3),
        );
        var exitCompleted = false;
        final exit = harness.sdk.exitProtectionMode().then((status) {
          exitCompleted = true;
          return status;
        });
        try {
          await pumpEventQueue(times: 12);
          expect(harness.adapter.stopCalls, 1);
          expect(
            exitCompleted,
            isFalse,
            reason:
                'exit must await actual Flutter reclaim after the old release settles',
          );
          release.complete();
          await handoff.timeout(const Duration(seconds: 3));
          final stopped = await exit.timeout(const Duration(seconds: 3));
          await pumpEventQueue(times: 30);
          expect(stopped.modeState, ProtectionModeState.off);
          expect(stopped.bleOwner, ProtectionBleOwner.flutter);
          expect(harness.repository.reclaimCalls, 1);
          expect(
            harness.adapter.ensureReasons,
            isEmpty,
            reason:
                'stale native continuation must not restart the stopped runtime',
          );
          final reconnect = await harness.sdk
              .bootstrapPreferredDeviceReconnect(reason: 'test_exit_reclaim')
              .timeout(const Duration(seconds: 5));
          expect(
            reconnect.status,
            PreferredDeviceReconnectResultStatus.connected,
          );
          expect(
            await harness.ble.isConnected(MockBleClient.demoDeviceId),
            isTrue,
          );
          expect(harness.repository.reconnectTargets, isNotEmpty);
          expect(
            harness.repository.reconnectTargets.every(
              (id) => id == MockBleClient.demoDeviceId,
            ),
            isTrue,
          );
          expect(
            (await harness.sdk.getDeviceStatus()).deviceId,
            MockBleClient.demoDeviceId,
          );
        } finally {
          if (!release.isCompleted) release.complete();
          await handoff;
          await exit;
        }
      },
    );
  }

  test(
    'ownership release failure reaches exit caller and a later exit can reclaim',
    () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.initialize();
      final release = Completer<void>();
      harness.repository.releaseBarrier = release;
      harness.repository.releaseError = StateError('release failed');
      harness.adapter.snapshot = const ProtectionPlatformSnapshot(
        backgroundCapabilityReady: true,
        platform: ProtectionPlatform.android,
        serviceRunning: true,
        runtimeActive: true,
        runtimeState: ProtectionRuntimeState.active,
        coverageLevel: ProtectionCoverageLevel.partial,
        bleOwner: ProtectionBleOwner.androidService,
        activeDeviceId: MockBleClient.demoDeviceId,
        protectedDeviceId: MockBleClient.demoDeviceId,
      );
      final handoff = harness.sdk.rehydrateProtectionState();
      final handoffFailure = expectLater(handoff, throwsA(isA<StateError>()));
      await harness.repository.releaseStarted.future.timeout(
        const Duration(seconds: 3),
      );
      final exit = harness.sdk.exitProtectionMode();
      final exitFailure = expectLater(exit, throwsA(isA<StateError>()));
      try {
        await pumpEventQueue(times: 8);
        release.complete();
        await Future.wait([handoffFailure, exitFailure]);
        expect(harness.adapter.ensureReasons, isEmpty);
        expect(harness.repository.reclaimCalls, 0);
        harness.repository.releaseError = null;
        harness.repository.releaseBarrier = null;
        final retried = await harness.sdk.exitProtectionMode();
        expect(retried.modeState, ProtectionModeState.off);
        expect(retried.bleOwner, ProtectionBleOwner.flutter);
        expect(harness.repository.reclaimCalls, 1);
        expect(harness.adapter.ensureReasons, isEmpty);
      } finally {
        if (!release.isCompleted) release.complete();
        await handoffFailure;
        await exitFailure;
      }
    },
  );

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
  late final repository = _BlockingOwnershipRepository(
    runtimeProvider: provider,
  );
  final store = MemorySharedPrefsSdkStore();
  late final sdk = EixamConnectSdkImpl(
    sosRepository: FakeSosRepository(),
    trackingRepository: FakeTrackingRepository(),
    telemetryRepository: FakeTelemetryRepository(),
    contactsRepository: FakeContactsRepository(),
    deviceRepository: repository,
    deviceRegistryRepository: FakeSdkDeviceRegistryRepository(),
    deathManRepository: FakeDeathManRepository(),
    permissionsRepository: FakePermissionsRepository(
      permissionState: const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      ),
    ),
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
  int stopCalls = 0;
  final ensureReasons = <String>[];

  @override
  Future<void> ensureProtectionRuntimeActive({
    String reason = 'app_foreground_resume',
  }) async {
    ensureReasons.add(reason);
  }

  @override
  Future<void> stopProtectionRuntime() async {
    stopCalls++;
    snapshot = ProtectionPlatformSnapshot(
      backgroundCapabilityReady: true,
      platform: snapshot.platform,
      bleOwner: ProtectionBleOwner.flutter,
    );
  }

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

class _BlockingOwnershipRepository extends InMemoryDeviceRepository {
  _BlockingOwnershipRepository({required super.runtimeProvider});
  Completer<void>? releaseBarrier;
  Object? releaseError;
  final releaseStarted = Completer<void>();
  int reclaimCalls = 0;
  final reconnectTargets = <String>[];
  @override
  Future<DeviceStatus> reconnectDevice({
    required PreferredDevice device,
    String? attemptId,
    bool Function()? canCreateGatt,
  }) {
    reconnectTargets.add(device.deviceId);
    return super.reconnectDevice(
      device: device,
      attemptId: attemptId,
      canCreateGatt: canCreateGatt,
    );
  }

  @override
  Future<DeviceStatus> releaseBleOwnershipToProtectionMode({
    required String reason,
  }) async {
    final barrier = releaseBarrier;
    if (barrier != null) {
      if (!releaseStarted.isCompleted) releaseStarted.complete();
      await barrier.future;
    }
    final error = releaseError;
    if (error != null) throw error;
    return super.releaseBleOwnershipToProtectionMode(reason: reason);
  }

  @override
  Future<DeviceStatus> reclaimBleOwnershipFromProtectionMode({
    required String reason,
  }) {
    reclaimCalls++;
    return super.reclaimBleOwnershipFromProtectionMode(reason: reason);
  }
}
