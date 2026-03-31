import '../entities/backend_registered_device.dart';

abstract class SdkDeviceRegistryRepository {
  Future<List<BackendRegisteredDevice>> listRegisteredDevices();

  Future<BackendRegisteredDevice> upsertRegisteredDevice({
    required String hardwareId,
    required String firmwareVersion,
    required String hardwareModel,
    required DateTime pairedAt,
  });

  Future<void> removeRegisteredDevice(String deviceId);
}
