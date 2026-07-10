import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/repositories/geolocator_tracking_repository.dart';
import 'package:eixam_connect_flutter/src/data/repositories/in_memory_device_repository.dart';
import 'package:eixam_connect_flutter/src/device/ble_device_runtime_provider.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/device/mock_ble_client.dart';
import '../support/fakes/fake_device_runtime_provider.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EixamConnectSdkImpl dispose', () {
    tearDown(() async {
      await BleDebugRegistry.instance.resetForLifecycle();
    });

    test('cascades into InMemoryDeviceRepository.dispose', () async {
      final runtimeProvider = FakeDeviceRuntimeProvider();
      final deviceRepository = InMemoryDeviceRepository(
        runtimeProvider: runtimeProvider,
      );
      final repositoryDone = expectLater(
        deviceRepository.watchDeviceStatus(),
        emitsDone,
      );
      final sdk = _buildSdk(
        deviceRepository: deviceRepository,
        disposeCallback: () => deviceRepository.dispose(),
      );

      await sdk.dispose();

      await repositoryDone;
      await runtimeProvider.dispose();
    });

    test('cascades into BleDeviceRuntimeProvider.dispose', () async {
      final bleClient = MockBleClient();
      final runtimeProvider = BleDeviceRuntimeProvider(bleClient: bleClient);
      final deviceRepository = InMemoryDeviceRepository(
        runtimeProvider: runtimeProvider,
      );
      final incomingDone = expectLater(
        runtimeProvider.watchIncomingEvents(),
        emitsDone,
      );
      final runtimeStatusDone = expectLater(
        runtimeProvider.watchRuntimeStatus(),
        emitsDone,
      );
      final sdk = _buildSdk(
        deviceRepository: deviceRepository,
        deviceSosController: runtimeProvider.deviceSosController,
        bleIncomingEvents: runtimeProvider.watchIncomingEvents(),
        disposeCallback: () async {
          await deviceRepository.dispose();
          await runtimeProvider.dispose();
        },
      );

      await sdk.dispose();

      await incomingDone;
      await runtimeStatusDone;
      await bleClient.dispose();
    });

    test('stops heartbeat timer and closes device status controller', () async {
      final runtimeProvider = FakeDeviceRuntimeProvider();
      runtimeProvider.pairResult = buildDeviceStatus();
      final deviceRepository = InMemoryDeviceRepository(
        runtimeProvider: runtimeProvider,
        heartbeatInterval: const Duration(milliseconds: 10),
      );
      final sdk = _buildSdk(
        deviceRepository: deviceRepository,
        disposeCallback: () => deviceRepository.dispose(),
      );

      await deviceRepository.pairDevice(pairingCode: '1234');
      await Future<void>.delayed(const Duration(milliseconds: 25));
      final refreshCountBeforeDispose = runtimeProvider.refreshCallCount;
      expect(refreshCountBeforeDispose, greaterThan(0));

      await sdk.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(runtimeProvider.refreshCallCount, refreshCountBeforeDispose);

      await runtimeProvider.dispose();
    });

    test('double dispose is safe and invokes cascade once', () async {
      final runtimeProvider = FakeDeviceRuntimeProvider();
      final deviceRepository = InMemoryDeviceRepository(
        runtimeProvider: runtimeProvider,
      );
      var cascadeCalls = 0;
      final sdk = _buildSdk(
        deviceRepository: deviceRepository,
        disposeCallback: () async {
          cascadeCalls += 1;
          await deviceRepository.dispose();
        },
      );

      await sdk.dispose();
      await sdk.dispose();

      expect(cascadeCalls, 1);
      await runtimeProvider.dispose();
    });

    test('cascades into geolocator repository and BLE debug registry lifecycle',
        () async {
      final runtimeProvider = FakeDeviceRuntimeProvider();
      final deviceRepository = InMemoryDeviceRepository(
        runtimeProvider: runtimeProvider,
      );
      final trackingRepository = GeolocatorTrackingRepository(
        permissionsRepository: FakePermissionsRepository(),
      );
      final trackingDone = expectLater(
        trackingRepository.watchTrackingState(),
        emitsInOrder(<Object>[TrackingState.idle, emitsDone]),
      );
      BleDebugRegistry.instance.recordEvent('dispose cascade marker');
      final registryDone = expectLater(
        BleDebugRegistry.instance.watch(),
        emitsDone,
      );
      final sdk = _buildSdk(
        deviceRepository: deviceRepository,
        trackingRepository: trackingRepository,
        disposeCallback: () async {
          await trackingRepository.dispose();
          await deviceRepository.dispose();
          await BleDebugRegistry.instance.resetForLifecycle();
        },
      );

      await sdk.dispose();

      await trackingDone;
      await registryDone;
      expect(BleDebugRegistry.instance.currentState.events, isEmpty);
      await runtimeProvider.dispose();
    });
  });

  group('BleDebugRegistry lifecycle', () {
    tearDown(() async {
      await BleDebugRegistry.instance.resetForLifecycle();
    });

    test('resetForLifecycle closes old listeners and replaces controller',
        () async {
      final firstDone = expectLater(
        BleDebugRegistry.instance.watch(),
        emitsDone,
      );

      await BleDebugRegistry.instance.resetForLifecycle();

      await firstDone;
      final nextStates = <Object>[];
      final subscription =
          BleDebugRegistry.instance.watch().listen(nextStates.add);
      BleDebugRegistry.instance.recordEvent('after reset');
      await Future<void>.delayed(Duration.zero);

      expect(nextStates, isNotEmpty);
      expect(
        BleDebugRegistry.instance.currentState.events.single.message,
        'after reset',
      );
      await subscription.cancel();
    });
  });
}

EixamConnectSdkImpl _buildSdk({
  required DeviceRepository deviceRepository,
  TrackingRepository? trackingRepository,
  DeviceSosController? deviceSosController,
  Stream<BleIncomingEvent> bleIncomingEvents =
      const Stream<BleIncomingEvent>.empty(),
  Future<void> Function()? disposeCallback,
}) {
  final localStore = MemorySharedPrefsSdkStore();
  return EixamConnectSdkImpl(
    sosRepository: FakeSosRepository(),
    trackingRepository: trackingRepository ?? FakeTrackingRepository(),
    telemetryRepository: FakeTelemetryRepository(),
    contactsRepository: FakeContactsRepository(),
    deviceRepository: deviceRepository,
    deviceRegistryRepository: FakeSdkDeviceRegistryRepository(),
    deathManRepository: FakeDeathManRepository(),
    permissionsRepository: FakePermissionsRepository(),
    notificationsRepository: FakeNotificationsRepository(),
    realtimeClient: FakeRealtimeClient(),
    deviceSosController: deviceSosController ?? DeviceSosController(),
    bleIncomingEvents: bleIncomingEvents,
    preferredBleDeviceStore: PreferredBleDeviceStore(localStore: localStore),
    localStore: localStore,
    protectionPlatformAdapter: const NoopProtectionPlatformAdapter(),
    backgroundTelemetryPlatformAdapter:
        const NoopBackgroundTelemetryPlatformAdapter(),
    disposeCallback: disposeCallback,
  );
}
