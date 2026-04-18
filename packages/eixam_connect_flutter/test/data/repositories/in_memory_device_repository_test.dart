import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/data/repositories/in_memory_device_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/builders/device_status_builder.dart';
import '../../support/fakes/fake_device_runtime_provider.dart';
import '../../support/fakes/memory_shared_prefs_sdk_store.dart';

void main() {
  group('InMemoryDeviceRepository', () {
    test('pairDevice emits lifecycle progress and persists runtime status',
        () async {
      final store = MemorySharedPrefsSdkStore();
      final runtimeProvider = FakeDeviceRuntimeProvider()
        ..pairResult = buildDeviceStatus(
          paired: true,
          activated: false,
          connected: true,
          lifecycleState: DeviceLifecycleState.paired,
        )
        ..unpairResult = buildDeviceStatus(
          paired: false,
          activated: false,
          connected: false,
          lifecycleState: DeviceLifecycleState.unpaired,
          batteryLevel: null,
          batteryState: null,
          batterySource: null,
          signalQuality: null,
        );
      final repository = InMemoryDeviceRepository(
        runtimeProvider: runtimeProvider,
        localStore: store,
      );
      final emittedStatuses = <DeviceStatus>[];
      final subscription =
          repository.watchDeviceStatus().listen(emittedStatuses.add);

      try {
        final result = await repository.pairDevice(pairingCode: '1234');
        await Future<void>.delayed(Duration.zero);

        expect(result.lifecycleState, DeviceLifecycleState.paired);
        expect(
            emittedStatuses.first.lifecycleState, DeviceLifecycleState.pairing);
        expect(
            emittedStatuses.last.lifecycleState, DeviceLifecycleState.paired);
        expect(
          store.jsonValues[SharedPrefsSdkStore.deviceStatusKey]
              ?['lifecycleState'],
          DeviceLifecycleState.paired.name,
        );
      } finally {
        await repository.unpairDevice();
        await subscription.cancel();
        await runtimeProvider.dispose();
      }
    });

    test('pairDevice stores failure status when runtime pairing throws',
        () async {
      final runtimeProvider = FakeDeviceRuntimeProvider()
        ..pairError = const DeviceException(
          'E_DEVICE_PAIR_FAILED',
          'Pairing failed',
        );
      final repository = InMemoryDeviceRepository(
        runtimeProvider: runtimeProvider,
        localStore: MemorySharedPrefsSdkStore(),
      );

      await expectLater(
        repository.pairDevice(pairingCode: 'bad'),
        throwsA(isA<DeviceException>()),
      );

      final status = await repository.getDeviceStatus();
      expect(status.lifecycleState, DeviceLifecycleState.error);
      expect(status.provisioningError, 'Pairing failed');
      await runtimeProvider.dispose();
    });

    test('restoreState hydrates persisted device status', () async {
      final store = MemorySharedPrefsSdkStore()
        ..jsonValues[SharedPrefsSdkStore.deviceStatusKey] = <String, dynamic>{
          'deviceId': 'device-42',
          'deviceAlias': 'Field Unit',
          'model': 'EIXAM R1',
          'paired': true,
          'activated': true,
          'connected': false,
          'batteryLevel': 3,
          'batteryState': DeviceBatteryLevel.ok.name,
          'batterySource': DeviceBatterySource.unknown.name,
          'firmwareVersion': '1.2.3',
          'lastSeen': DateTime.utc(2026, 1, 1, 12).toIso8601String(),
          'lastSyncedAt': DateTime.utc(2026, 1, 1, 12).toIso8601String(),
          'signalQuality': 4,
          'lifecycleState': DeviceLifecycleState.ready.name,
          'provisioningError': null,
        };
      final runtimeProvider = FakeDeviceRuntimeProvider();
      final repository = InMemoryDeviceRepository(
        runtimeProvider: runtimeProvider,
        localStore: store,
      );

      await repository.restoreState();

      final status = await repository.getDeviceStatus();
      expect(status.deviceId, 'device-42');
      expect(status.lifecycleState, DeviceLifecycleState.ready);
      expect(status.effectiveBatteryState, DeviceBatteryLevel.ok);
      expect(status, isNot(isA<BackendRegisteredDevice>()));
      await runtimeProvider.dispose();
    });

    test('refreshDeviceStatus does not emit when effective status is unchanged',
        () async {
      final runtimeProvider = FakeDeviceRuntimeProvider()
        ..refreshResult = const DeviceStatus(
          deviceId: 'demo-device',
          deviceAlias: 'Demo Beacon',
          model: 'EIXAM R1',
          paired: false,
          activated: false,
          connected: false,
          batteryLevel: null,
          batteryState: null,
          batterySource: null,
          firmwareVersion: '0.1.0-demo',
          lifecycleState: DeviceLifecycleState.unpaired,
        ).copyWith(
          lastSyncedAt: DateTime.utc(2026, 1, 1, 12),
        );
      final repository = InMemoryDeviceRepository(
        runtimeProvider: runtimeProvider,
        localStore: MemorySharedPrefsSdkStore(),
      );
      final emittedStatuses = <DeviceStatus>[];
      final subscription =
          repository.watchDeviceStatus().listen(emittedStatuses.add);

      try {
        final refreshed = await repository.refreshDeviceStatus();
        await Future<void>.delayed(Duration.zero);

        expect(runtimeProvider.refreshCallCount, 1);
        expect(refreshed.lastSyncedAt, DateTime.utc(2026, 1, 1, 12));
        expect(emittedStatuses, isEmpty);
      } finally {
        await subscription.cancel();
        await runtimeProvider.dispose();
      }
    });
  });
}
