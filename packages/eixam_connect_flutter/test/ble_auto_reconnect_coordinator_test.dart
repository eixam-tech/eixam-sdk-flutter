import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/preferred_ble_device.dart';
import 'package:eixam_connect_flutter/src/sdk/ble_auto_reconnect_coordinator.dart';
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

      expect(repository.pairCallCount, 1);
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
  });
}

class _FakeDeviceRepository implements DeviceRepository {
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

  @override
  Future<DeviceStatus> activateDevice({required String activationCode}) async {
    return _status;
  }

  @override
  Future<DeviceStatus> getDeviceStatus() async => _status;

  @override
  Future<DeviceStatus> pairDevice({required String pairingCode}) async {
    pairCallCount++;
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
  Future<DeviceStatus> refreshDeviceStatus() async => _status;

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
