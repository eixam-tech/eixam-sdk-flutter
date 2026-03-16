import 'dart:math';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'device_runtime_provider.dart';

/// Demo-friendly runtime provider that simulates device lifecycle changes.
class MockDeviceRuntimeProvider implements DeviceRuntimeProvider {
  final Random _random = Random();

  @override
  Future<DeviceStatus> pair({required DeviceStatus currentStatus, required String pairingCode}) async {
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
      lastSeen: DateTime.now(),
      lastSyncedAt: DateTime.now(),
      signalQuality: 4,
      clearProvisioningError: true,
    );
  }

  @override
  Future<DeviceStatus> activate({required DeviceStatus currentStatus, required String activationCode}) async {
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
      lastSeen: DateTime.now(),
      lastSyncedAt: DateTime.now(),
      signalQuality: 4,
      clearProvisioningError: true,
    );
  }

  @override
  Future<DeviceStatus> refresh(DeviceStatus currentStatus) async {
    if (!currentStatus.paired) return currentStatus;

    final battery = ((currentStatus.batteryLevel ?? 80) - _random.nextInt(2)).clamp(15, 100);
    final activated = currentStatus.activated;
    return currentStatus.copyWith(
      connected: true,
      batteryLevel: battery,
      lastSeen: DateTime.now(),
      lastSyncedAt: DateTime.now(),
      signalQuality: 2 + _random.nextInt(3),
      lifecycleState: activated ? DeviceLifecycleState.ready : DeviceLifecycleState.paired,
      clearProvisioningError: true,
    );
  }

  @override
  Future<DeviceStatus> unpair(DeviceStatus currentStatus) async {
    return currentStatus.copyWith(
      paired: false,
      activated: false,
      connected: false,
      lifecycleState: DeviceLifecycleState.unpaired,
      lastSeen: DateTime.now(),
      lastSyncedAt: DateTime.now(),
      provisioningError: null,
      signalQuality: null,
    );
  }
}
