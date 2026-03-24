import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/device_runtime_provider.dart';

class FakeDeviceRuntimeProvider implements DeviceRuntimeProvider {
  final StreamController<DeviceStatus> _runtimeStatusController =
      StreamController<DeviceStatus>.broadcast();

  DeviceStatus? pairResult;
  DeviceStatus? activateResult;
  DeviceStatus? refreshResult;
  DeviceStatus? unpairResult;
  DeviceException? pairError;
  DeviceException? activateError;
  int refreshCallCount = 0;

  @override
  Stream<DeviceStatus> watchRuntimeStatus() => _runtimeStatusController.stream;

  void emitRuntimeStatus(DeviceStatus status) {
    _runtimeStatusController.add(status);
  }

  @override
  Future<DeviceStatus> pair({
    required DeviceStatus currentStatus,
    required String pairingCode,
  }) async {
    if (pairError != null) {
      throw pairError!;
    }
    return pairResult ?? currentStatus;
  }

  @override
  Future<DeviceStatus> activate({
    required DeviceStatus currentStatus,
    required String activationCode,
  }) async {
    if (activateError != null) {
      throw activateError!;
    }
    return activateResult ?? currentStatus;
  }

  @override
  Future<DeviceStatus> refresh(DeviceStatus currentStatus) async {
    refreshCallCount++;
    return refreshResult ?? currentStatus;
  }

  @override
  Future<DeviceStatus> unpair(DeviceStatus currentStatus) async {
    return unpairResult ??
        currentStatus.copyWith(
          paired: false,
          activated: false,
          connected: false,
          lifecycleState: DeviceLifecycleState.unpaired,
          batteryLevel: null,
          batteryState: null,
          batterySource: null,
          signalQuality: null,
          clearProvisioningError: true,
        );
  }

  Future<void> dispose() async {
    await _runtimeStatusController.close();
  }
}
