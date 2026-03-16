import '../entities/device_status.dart';

/// Abstraction for device pairing, activation and runtime status.
abstract class DeviceRepository {
  Future<DeviceStatus> pairDevice({required String pairingCode});
  Future<DeviceStatus> activateDevice({required String activationCode});
  Future<DeviceStatus> getDeviceStatus();
  Future<DeviceStatus> refreshDeviceStatus();
  Future<void> unpairDevice();
  Stream<DeviceStatus> watchDeviceStatus();
}
