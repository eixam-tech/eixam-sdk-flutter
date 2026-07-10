import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/device_runtime_provider.dart';

class FakeDeviceRuntimeProvider implements DeviceRuntimeProvider {
  final StreamController<DeviceStatus> _runtimeStatusController =
      StreamController<DeviceStatus>.broadcast();

  DeviceStatus? pairResult;
  DeviceStatus? reconnectResult;
  DeviceStatus? activateResult;
  DeviceStatus? refreshResult;
  DeviceStatus? unpairResult;
  DeviceException? pairError;
  Object? reconnectError;
  DeviceException? activateError;
  final List<Object> refreshErrors = <Object>[];
  int refreshCallCount = 0;
  DeviceRefreshMode? lastRefreshMode;
  bool? lastForceFirmwareRead;

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
  Future<DeviceStatus> reconnect({
    required DeviceStatus currentStatus,
    required PreferredDevice preferredDevice,
    String? attemptId,
  }) async {
    if (reconnectError != null) {
      throw reconnectError!;
    }
    return reconnectResult ??
        currentStatus.copyWith(
          deviceId: preferredDevice.deviceId,
          deviceAlias: preferredDevice.displayName ?? currentStatus.deviceAlias,
          paired: true,
          connected: true,
          lifecycleState: currentStatus.activated
              ? DeviceLifecycleState.ready
              : DeviceLifecycleState.paired,
          clearProvisioningError: true,
        );
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
  Future<DeviceStatus> refresh(
    DeviceStatus currentStatus, {
    DeviceRefreshMode mode = DeviceRefreshMode.manual,
    bool forceFirmwareRead = false,
  }) async {
    refreshCallCount++;
    lastRefreshMode = mode;
    lastForceFirmwareRead = forceFirmwareRead;
    if (refreshErrors.isNotEmpty) {
      throw refreshErrors.removeAt(0);
    }
    return refreshResult ?? currentStatus;
  }

  @override
  Future<RuntimeIdentitySnapshot> getRuntimeIdentitySnapshot(
    DeviceStatus currentStatus,
  ) async {
    return RuntimeIdentitySnapshot(
      connectedBleNodeId: null,
      deviceId: currentStatus.connected ? currentStatus.deviceId : null,
      serviceBleConnected: currentStatus.connected,
      commandCapable: false,
      readinessReason: currentStatus.connected
          ? RuntimeIdentityReadinessReason.commandPathNotReady
          : RuntimeIdentityReadinessReason.noConnectedDevice,
      lastUpdatedAt: currentStatus.lastSyncedAt ?? currentStatus.lastSeen,
    );
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
