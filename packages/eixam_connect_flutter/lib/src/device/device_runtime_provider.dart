import 'package:eixam_connect_core/eixam_connect_core.dart';

enum DeviceRefreshMode {
  heartbeat,
  manual,
}

/// Abstraction for the runtime source of device state.
///
/// A future BLE implementation can implement this contract without changing the
/// public SDK or the repository orchestration layer.
abstract class DeviceRuntimeProvider {
  Stream<DeviceStatus> watchRuntimeStatus();
  Future<DeviceStatus> pair(
      {required DeviceStatus currentStatus, required String pairingCode});
  Future<DeviceStatus> reconnect({
    required DeviceStatus currentStatus,
    required PreferredDevice preferredDevice,
  });
  Future<DeviceStatus> activate(
      {required DeviceStatus currentStatus, required String activationCode});
  Future<DeviceStatus> refresh(
    DeviceStatus currentStatus, {
    DeviceRefreshMode mode = DeviceRefreshMode.manual,
    bool forceFirmwareRead = false,
  });
  Future<RuntimeIdentitySnapshot> getRuntimeIdentitySnapshot(
    DeviceStatus currentStatus,
  );
  Future<DeviceStatus> unpair(DeviceStatus currentStatus);
}
