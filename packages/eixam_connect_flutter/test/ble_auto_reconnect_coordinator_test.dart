import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/known_device_reconnect_repository.dart';
import 'package:eixam_connect_flutter/src/device/preferred_ble_device.dart';
import 'package:eixam_connect_flutter/src/sdk/ble_auto_reconnect_coordinator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('BleAutoReconnectCoordinator', () {
    test('tries startup auto-connect when a preferred device exists', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository();
      final store = PreferredBleDeviceStore(
        localStore: SharedPrefsSdkStore(),
      );
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      await coordinator.tryAutoConnectOnStartup();

      expect(repository.reconnectCallCount, 1);
      expect(repository.pairCallCount, 0);
      expect(
        BleDebugRegistry.instance.currentState.selectedDeviceId,
        'ble-demo-r1',
      );
      await coordinator.dispose();
    });

    test('skips auto-connect when manual disconnect is active', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository();
      final store = PreferredBleDeviceStore(
        localStore: SharedPrefsSdkStore(),
      );
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      await coordinator.onManualDisconnect();
      await coordinator.tryAutoConnectOnResume();

      expect(repository.pairCallCount, 0);
      expect(await store.readManualDisconnectRequested(), isTrue);
      await coordinator.dispose();
    });

    test('tries auto-connect again when app returns to foreground', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository();
      final store = PreferredBleDeviceStore(
        localStore: SharedPrefsSdkStore(),
      );
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );

      coordinator.setAppForeground(false);
      repository.setDisconnected();
      coordinator.setAppForeground(true);
      await Future<void>.delayed(Duration.zero);

      expect(repository.reconnectCallCount, 1);
      expect(repository.lastReconnectedDeviceId, 'ble-demo-r1');
      expect(repository.lastPairingCode, isNull);
      await coordinator.dispose();
    });

    test('tries resume auto-connect for a known preferred device', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository();
      final store = PreferredBleDeviceStore(
        localStore: SharedPrefsSdkStore(),
      );
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      repository.setDisconnected();

      await coordinator.tryAutoConnectOnResume();

      expect(repository.reconnectCallCount, 1);
      expect(repository.lastReconnectedDeviceId, 'ble-demo-r1');
      expect(repository.lastPairingCode, isNull);
      await coordinator.dispose();
    });

    test(
        'iOS skips auto-connect and requires scan when preferred id is not a CoreBluetooth UUID',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository();
      final store = PreferredBleDeviceStore(
        localStore: SharedPrefsSdkStore(),
      );
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
        isIosPlatform: () => true,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      repository.setDisconnected();

      await coordinator.tryAutoConnectOnResume();

      expect(repository.reconnectCallCount, 0);
      expect(repository.lastReconnectedDeviceId, isNull);
      expect(
        BleDebugRegistry.instance.currentState.events
            .map((event) => event.message),
        containsAll(<String>[
          'DEVICE_IDENTITY_RESOLVED platform=ios logicalId=ble-demo-r1 remoteIdPresent=false',
          'BLE_RECONNECT_REQUIRES_SCAN platform=ios reason=missing_valid_remote_id',
        ]),
      );
      await coordinator.dispose();
    });

    test('stops auto-connect when phone Bluetooth bond was removed', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository()
        ..pairErrors = <Object>[
          const DeviceException(
            'E_DEVICE_MOBILE_BOND_REQUIRED',
            'The device is no longer paired in the phone Bluetooth settings.',
          ),
        ];
      final store = PreferredBleDeviceStore(
        localStore: SharedPrefsSdkStore(),
      );
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      await coordinator.tryAutoConnectOnResume();

      expect(repository.reconnectCallCount, 1);
      expect(await store.getPreferredDevice(), isNull);
      expect(await store.readManualDisconnectRequested(), isTrue);
      expect(
        BleDebugRegistry.instance.currentState.events
            .map((event) => event.message),
        contains(
          'BLE_AUTO_RECONNECT_STOPPED reason=android_bond_missing hardwareId=ble-demo-r1',
        ),
      );
      await coordinator.dispose();
    });

    test('uses restored paired device id when preferred store is empty',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository()..setDisconnected();
      final store = PreferredBleDeviceStore(
        localStore: SharedPrefsSdkStore(),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      await coordinator.tryAutoConnectOnStartup();

      expect(repository.reconnectCallCount, 1);
      expect(repository.lastReconnectedDeviceId, 'demo-device');
      await coordinator.dispose();
    });

    test(
        'rebinds an already connected device when command channel is not ready',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository()
        ..setConnected(commandCapable: false);
      final store = PreferredBleDeviceStore(
        localStore: SharedPrefsSdkStore(),
      );
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      await coordinator.tryAutoConnectOnResume();

      expect(repository.refreshCallCount, 1);
      expect(repository.reconnectCallCount, 1);
      expect(repository.lastReconnectedDeviceId, 'ble-demo-r1');
      expect(
        BleDebugRegistry.instance.currentState.events
            .map((event) => event.message),
        contains(
          'BLE_AUTO_CONNECT_REBIND trigger=resume reason=command_channel_not_ready',
        ),
      );
      await coordinator.dispose();
    });

    test('skips already connected device when command channel is ready',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository()
        ..setConnected(commandCapable: true);
      final store = PreferredBleDeviceStore(
        localStore: SharedPrefsSdkStore(),
      );
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      await coordinator.tryAutoConnectOnResume();

      expect(repository.refreshCallCount, 1);
      expect(repository.reconnectCallCount, 0);
      expect(
        BleDebugRegistry.instance.currentState.events
            .map((event) => event.message),
        contains(
          'BLE_AUTO_CONNECT_SKIPPED trigger=resume reason=command_channel_ready',
        ),
      );
      await coordinator.dispose();
    });

    test('retries manual connect once for transient disconnect failures',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository()
        ..pairErrors = <Object>[
          PlatformException(
            code: 'deviceDisconnected',
            message: 'deviceDisconnected',
          ),
        ];
      final store = PreferredBleDeviceStore(
        localStore: SharedPrefsSdkStore(),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );

      final status = await coordinator.pairDeviceManually(pairingCode: '1234');

      expect(status.connected, isTrue);
      expect(repository.pairCallCount, 2);
      expect(
        BleDebugRegistry.instance.currentState.events
            .map((event) => event.message),
        contains('manual_connect_retry_start'),
      );
      expect(
        BleDebugRegistry.instance.currentState.events
            .map((event) => event.message),
        contains('manual_connect_retry_success'),
      );
      await coordinator.dispose();
    });

    test('does not retry auto-connect for transient disconnect failures',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository()
        ..pairErrors = <Object>[
          PlatformException(
            code: 'deviceDisconnected',
            message: 'deviceDisconnected',
          ),
        ];
      final store = PreferredBleDeviceStore(
        localStore: SharedPrefsSdkStore(),
      );
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );

      await coordinator.tryAutoConnectOnStartup();

      expect(repository.reconnectCallCount, 1);
      expect(repository.pairCallCount, 0);
      expect(
        BleDebugRegistry.instance.currentState.events
            .map((event) => event.message)
            .where((message) => message == 'manual_connect_retry_start'),
        isEmpty,
      );
      await coordinator.dispose();
    });
  });
}

class _FakeDeviceRepository
    implements DeviceRepository, KnownDeviceReconnectRepository {
  final StreamController<DeviceStatus> _controller =
      StreamController<DeviceStatus>.broadcast();

  DeviceStatus _status = const DeviceStatus(
    deviceId: 'demo-device',
    deviceAlias: 'Demo Device',
    model: 'EIXAM R1',
    paired: false,
    activated: false,
    connected: false,
    lifecycleState: DeviceLifecycleState.unpaired,
  );

  int pairCallCount = 0;
  int reconnectCallCount = 0;
  int refreshCallCount = 0;
  String? lastPairingCode;
  String? lastReconnectedDeviceId;
  List<Object> pairErrors = <Object>[];
  bool _commandCapable = false;

  void setDisconnected() {
    _status = _status.copyWith(
      paired: true,
      connected: false,
      lifecycleState: DeviceLifecycleState.paired,
      clearProvisioningError: true,
    );
    _controller.add(_status);
  }

  void setConnected({required bool commandCapable}) {
    _commandCapable = commandCapable;
    _status = _status.copyWith(
      deviceId: 'ble-demo-r1',
      deviceAlias: 'EIXAM Demo',
      paired: true,
      connected: true,
      lifecycleState: DeviceLifecycleState.paired,
      clearProvisioningError: true,
    );
    _controller.add(_status);
  }

  @override
  Future<DeviceStatus> activateDevice({required String activationCode}) async {
    return _status;
  }

  @override
  Future<DeviceStatus> getDeviceStatus() async => _status;

  @override
  Future<DeviceStatus> pairDevice({required String pairingCode}) async {
    pairCallCount++;
    lastPairingCode = pairingCode;
    if (pairErrors.isNotEmpty) {
      throw pairErrors.removeAt(0);
    }
    _status = _status.copyWith(
      deviceId: 'ble-demo-r1',
      deviceAlias: 'EIXAM Demo',
      paired: true,
      connected: true,
      lifecycleState: DeviceLifecycleState.paired,
      clearProvisioningError: true,
    );
    _controller.add(_status);
    return _status;
  }

  @override
  Future<DeviceStatus> reconnectDevice({
    required PreferredDevice device,
    String? attemptId,
  }) async {
    reconnectCallCount++;
    lastReconnectedDeviceId = device.deviceId;
    if (pairErrors.isNotEmpty) {
      throw pairErrors.removeAt(0);
    }
    _status = _status.copyWith(
      deviceId: device.deviceId,
      deviceAlias: device.displayName ?? 'EIXAM Demo',
      paired: true,
      connected: true,
      lifecycleState: DeviceLifecycleState.paired,
      clearProvisioningError: true,
    );
    _commandCapable = true;
    _controller.add(_status);
    return _status;
  }

  @override
  Future<DeviceStatus> refreshDeviceStatus() async {
    refreshCallCount++;
    return _status;
  }

  @override
  Future<RuntimeIdentitySnapshot> getRuntimeIdentitySnapshot() async {
    return RuntimeIdentitySnapshot(
      connectedBleNodeId: null,
      deviceId: _status.connected ? _status.deviceId : null,
      serviceBleConnected: _status.connected,
      commandCapable: _commandCapable,
      readinessReason: _status.connected && _commandCapable
          ? RuntimeIdentityReadinessReason.ready
          : _status.connected
              ? RuntimeIdentityReadinessReason.commandPathNotReady
              : RuntimeIdentityReadinessReason.noConnectedDevice,
      lastUpdatedAt: _status.lastSyncedAt ?? _status.lastSeen,
    );
  }

  @override
  Future<void> unpairDevice() async {
    _status = _status.copyWith(
      paired: false,
      connected: false,
      lifecycleState: DeviceLifecycleState.unpaired,
    );
    _controller.add(_status);
  }

  @override
  Stream<DeviceStatus> watchDeviceStatus() => _controller.stream;
}
