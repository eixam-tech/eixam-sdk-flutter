import 'dart:math';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'device_runtime_provider.dart';

/// Demo-friendly runtime provider that simulates device lifecycle changes.
class MockDeviceRuntimeProvider implements DeviceRuntimeProvider {
  final Random _random = Random();

  @override
  Stream<DeviceStatus> watchRuntimeStatus() =>
      const Stream<DeviceStatus>.empty();

  @override
  Future<DeviceStatus> pair(
      {required DeviceStatus currentStatus,
      required String pairingCode}) async {
    if (pairingCode.trim().length < 4) {
      throw const DeviceException.invalidPairingCode();
    }

    return currentStatus.copyWith(
      paired: true,
      activated: currentStatus.activated,
      connected: true,
      lifecycleState: currentStatus.activated
          ? DeviceLifecycleState.activated
          : DeviceLifecycleState.paired,
      batteryLevel:
          currentStatus.batteryLevel ?? DeviceBatteryLevel.ok.protocolValue,
      batteryState:
          currentStatus.effectiveBatteryState ?? DeviceBatteryLevel.ok,
      batterySource: currentStatus.batterySource ?? DeviceBatterySource.unknown,
      lastSeen: DateTime.now(),
      lastSyncedAt: DateTime.now(),
      signalQuality: 4,
      clearProvisioningError: true,
    );
  }

  @override
  Future<DeviceStatus> activate(
      {required DeviceStatus currentStatus,
      required String activationCode}) async {
    if (!currentStatus.paired) {
      throw const DeviceException.notPaired();
    }
    if (activationCode.trim().length < 4) {
      throw const DeviceException.invalidActivationCode();
    }

    return currentStatus.copyWith(
      activated: true,
      connected: true,
      lifecycleState: DeviceLifecycleState.ready,
      batteryLevel:
          currentStatus.batteryLevel ?? DeviceBatteryLevel.ok.protocolValue,
      batteryState:
          currentStatus.effectiveBatteryState ?? DeviceBatteryLevel.ok,
      batterySource: currentStatus.batterySource ?? DeviceBatterySource.unknown,
      lastSeen: DateTime.now(),
      lastSyncedAt: DateTime.now(),
      signalQuality: 4,
      clearProvisioningError: true,
    );
  }

  @override
  Future<DeviceStatus> refresh(DeviceStatus currentStatus) async {
    if (!currentStatus.paired) return currentStatus;

    final currentBatteryLevel =
        currentStatus.batteryLevel ?? DeviceBatteryLevel.ok.protocolValue;
    final battery = (currentBatteryLevel - _random.nextInt(2)).clamp(0, 3);
    final activated = currentStatus.activated;
    return currentStatus.copyWith(
      connected: true,
      batteryLevel: battery,
      batteryState: DeviceBatteryLevel.fromProtocolValue(battery),
      batterySource: DeviceBatterySource.unknown,
      lastSeen: DateTime.now(),
      lastSyncedAt: DateTime.now(),
      signalQuality: 2 + _random.nextInt(3),
      lifecycleState:
          activated ? DeviceLifecycleState.ready : DeviceLifecycleState.paired,
      clearProvisioningError: true,
    );
  }

  @override
  Future<DeviceStatus> unpair(DeviceStatus currentStatus) async {
    return DeviceStatus(
      deviceId: currentStatus.deviceId,
      canonicalHardwareId: currentStatus.canonicalHardwareId,
      deviceAlias: currentStatus.deviceAlias,
      model: currentStatus.model,
      paired: false,
      activated: false,
      connected: false,
      batteryLevel: null,
      batteryState: null,
      batterySource: null,
      firmwareVersion: currentStatus.firmwareVersion,
      lastSeen: DateTime.now(),
      lastSyncedAt: DateTime.now(),
      signalQuality: null,
      lifecycleState: DeviceLifecycleState.unpaired,
      provisioningError: null,
    );
  }
}
