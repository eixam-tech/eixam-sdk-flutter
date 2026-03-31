import 'package:eixam_connect_core/eixam_connect_core.dart';

class InMemorySdkDeviceRegistryRepository
    implements SdkDeviceRegistryRepository {
  final List<BackendRegisteredDevice> _devices = <BackendRegisteredDevice>[];

  @override
  Future<List<BackendRegisteredDevice>> listRegisteredDevices() async {
    return List<BackendRegisteredDevice>.unmodifiable(_devices);
  }

  @override
  Future<void> removeRegisteredDevice(String deviceId) async {
    _devices.removeWhere((device) => device.id == deviceId);
  }

  @override
  Future<BackendRegisteredDevice> upsertRegisteredDevice({
    required String hardwareId,
    required String firmwareVersion,
    required String hardwareModel,
    required DateTime pairedAt,
  }) async {
    final existingIndex =
        _devices.indexWhere((device) => device.hardwareId == hardwareId);
    final now = DateTime.now().toUtc();
    final device = BackendRegisteredDevice(
      id: existingIndex >= 0
          ? _devices[existingIndex].id
          : 'device-${_devices.length + 1}',
      hardwareId: hardwareId,
      firmwareVersion: firmwareVersion,
      hardwareModel: hardwareModel,
      pairedAt: pairedAt.toUtc(),
      createdAt: existingIndex >= 0 ? _devices[existingIndex].createdAt : now,
      updatedAt: now,
    );
    if (existingIndex >= 0) {
      _devices[existingIndex] = device;
    } else {
      _devices.add(device);
    }
    return device;
  }
}
