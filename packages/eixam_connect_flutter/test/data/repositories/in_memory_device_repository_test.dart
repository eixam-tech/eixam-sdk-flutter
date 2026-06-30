import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/data/repositories/in_memory_device_repository.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/builders/device_status_builder.dart';
import '../../support/fakes/fake_device_runtime_provider.dart';
import '../../support/fakes/memory_shared_prefs_sdk_store.dart';

void main() {
  group('InMemoryDeviceRepository', () {
    tearDown(() async {
      await BleDebugRegistry.instance.resetForLifecycle();
    });

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

    test('pairDevice clears paired state when system pairing is cancelled',
        () async {
      final runtimeProvider = FakeDeviceRuntimeProvider()
        ..pairError = const DeviceException(
          'E_DEVICE_MOBILE_BOND_REQUIRED',
          'The device is no longer paired in the phone Bluetooth settings.',
        );
      final repository = InMemoryDeviceRepository(
        runtimeProvider: runtimeProvider,
        localStore: MemorySharedPrefsSdkStore(),
      );

      await expectLater(
        repository.pairDevice(pairingCode: '1234'),
        throwsA(
          isA<DeviceException>().having(
            (error) => error.code,
            'code',
            'E_DEVICE_MOBILE_BOND_REQUIRED',
          ),
        ),
      );

      final status = await repository.getDeviceStatus();
      expect(status.paired, isFalse);
      expect(status.activated, isFalse);
      expect(status.connected, isFalse);
      expect(status.lifecycleState, DeviceLifecycleState.unpaired);
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

    test('restoreState downgrades persisted connected status before reconnect',
        () async {
      final store = MemorySharedPrefsSdkStore()
        ..jsonValues[SharedPrefsSdkStore.deviceStatusKey] = <String, dynamic>{
          'deviceId': 'device-42',
          'deviceAlias': 'Field Unit',
          'model': 'EIXAM R1',
          'paired': true,
          'activated': true,
          'connected': true,
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
      expect(status.paired, isTrue);
      expect(status.connected, isFalse);
      expect(status.lifecycleState, DeviceLifecycleState.paired);
      expect(status.provisioningError, isNull);
      await runtimeProvider.dispose();
    });

    test('reconnectDevice keeps paired runtime state for non-SDK BLE errors',
        () async {
      final runtimeProvider = FakeDeviceRuntimeProvider()
        ..reconnectError = StateError('platform reconnect failed');
      final repository = InMemoryDeviceRepository(
        runtimeProvider: runtimeProvider,
        localStore: MemorySharedPrefsSdkStore(),
      );

      await expectLater(
        repository.reconnectDevice(
          device: PreferredDevice(
            deviceId: 'device-42',
            displayName: 'Field Unit',
            lastConnectedAt: DateTime.utc(2026, 1, 1),
          ),
        ),
        throwsA(isA<StateError>()),
      );

      final status = await repository.getDeviceStatus();
      expect(status.paired, isTrue);
      expect(status.connected, isFalse);
      expect(status.lifecycleState, DeviceLifecycleState.paired);
      expect(status.provisioningError, isNull);
      await runtimeProvider.dispose();
    });

    test(
        'reconnectDevice clears paired state when phone Bluetooth bond is gone',
        () async {
      final runtimeProvider = FakeDeviceRuntimeProvider()
        ..reconnectError = const DeviceException(
          'E_DEVICE_MOBILE_BOND_REQUIRED',
          'The device is no longer paired in the phone Bluetooth settings.',
        );
      final repository = InMemoryDeviceRepository(
        runtimeProvider: runtimeProvider,
        localStore: MemorySharedPrefsSdkStore(),
      );

      await expectLater(
        repository.reconnectDevice(
          device: PreferredDevice(
            deviceId: 'device-42',
            displayName: 'Field Unit',
            lastConnectedAt: DateTime.utc(2026, 1, 1),
          ),
        ),
        throwsA(
          isA<DeviceException>().having(
            (error) => error.code,
            'code',
            'E_DEVICE_MOBILE_BOND_REQUIRED',
          ),
        ),
      );

      final status = await repository.getDeviceStatus();
      expect(status.paired, isFalse);
      expect(status.activated, isFalse);
      expect(status.connected, isFalse);
      expect(status.lifecycleState, DeviceLifecycleState.unpaired);
      await runtimeProvider.dispose();
    });

    test('reconnectDevice clears paired state when iOS pairing info is removed',
        () async {
      final runtimeProvider = FakeDeviceRuntimeProvider()
        ..reconnectError =
            const DeviceException.bleIosPairingInformationRemoved();
      final repository = InMemoryDeviceRepository(
        runtimeProvider: runtimeProvider,
        localStore: MemorySharedPrefsSdkStore(),
      );

      await expectLater(
        repository.reconnectDevice(
          device: PreferredDevice(
            deviceId: 'ios-corebluetooth-id',
            displayName: 'Field Unit',
            lastConnectedAt: DateTime.utc(2026, 1, 1),
          ),
        ),
        throwsA(
          isA<DeviceException>().having(
            (error) => error.code,
            'code',
            DeviceException.bleIosPairingInformationRemovedCode,
          ),
        ),
      );

      final status = await repository.getDeviceStatus();
      expect(status.paired, isFalse);
      expect(status.activated, isFalse);
      expect(status.connected, isFalse);
      expect(status.lifecycleState, DeviceLifecycleState.unpaired);
      expect(status.provisioningError, isNull);
      await runtimeProvider.dispose();
    });

    test(
        'markDeviceDisconnected keeps paired state and clears command readiness',
        () async {
      final store = MemorySharedPrefsSdkStore();
      final runtimeProvider = FakeDeviceRuntimeProvider()
        ..pairResult = buildDeviceStatus(
          paired: true,
          activated: true,
          connected: true,
          lifecycleState: DeviceLifecycleState.ready,
        );
      final repository = InMemoryDeviceRepository(
        runtimeProvider: runtimeProvider,
        localStore: store,
      );
      final emittedStatuses = <DeviceStatus>[];
      final subscription =
          repository.watchDeviceStatus().listen(emittedStatuses.add);

      try {
        await repository.pairDevice(pairingCode: '1234');
        final status = await repository.markDeviceDisconnected(
          reason: 'shutdown_command',
        );
        await Future<void>.delayed(Duration.zero);

        expect(status.paired, isTrue);
        expect(status.connected, isFalse);
        expect(status.lifecycleState, DeviceLifecycleState.paired);
        expect(status.provisioningError, isNull);
        expect(emittedStatuses.last.connected, isFalse);
        expect(
          store.jsonValues[SharedPrefsSdkStore.deviceStatusKey]?['connected'],
          isFalse,
        );
      } finally {
        await subscription.cancel();
        await runtimeProvider.dispose();
      }
    });

    test('refreshDeviceStatus does not emit when effective status is unchanged',
        () async {
      final runtimeProvider = FakeDeviceRuntimeProvider()
        ..refreshResult = const DeviceStatus(
          deviceId: '',
          deviceAlias: null,
          model: null,
          paired: false,
          activated: false,
          connected: false,
          batteryLevel: null,
          batteryState: null,
          batterySource: null,
          firmwareVersion: null,
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

    test('heartbeat catches refresh errors and keeps future ticks alive',
        () async {
      final runtimeProvider = FakeDeviceRuntimeProvider()
        ..pairResult = buildDeviceStatus(
          paired: true,
          activated: true,
          connected: true,
          lifecycleState: DeviceLifecycleState.ready,
        )
        ..refreshErrors.add(StateError('transient heartbeat failure'));
      final repository = InMemoryDeviceRepository(
        runtimeProvider: runtimeProvider,
        localStore: MemorySharedPrefsSdkStore(),
        heartbeatInterval: const Duration(milliseconds: 10),
      );

      try {
        await repository.pairDevice(pairingCode: '1234');
        await Future<void>.delayed(const Duration(milliseconds: 45));

        expect(runtimeProvider.refreshCallCount, greaterThanOrEqualTo(2));
        expect(
          BleDebugRegistry.instance.currentState.events.map((event) {
            return event.message;
          }),
          contains(
            'InMemoryDeviceRepository.heartbeat_failed -> errorType=StateError',
          ),
        );
      } finally {
        await repository.dispose();
        await runtimeProvider.dispose();
      }
    });
  });
}
