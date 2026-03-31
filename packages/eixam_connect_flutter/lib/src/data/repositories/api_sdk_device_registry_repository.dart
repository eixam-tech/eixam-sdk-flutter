import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../../mappers/sdk_device_registry_mapper.dart';
import '../datasources_remote/sdk_devices_remote_data_source.dart';

class ApiSdkDeviceRegistryRepository implements SdkDeviceRegistryRepository {
  ApiSdkDeviceRegistryRepository({
    required this.remoteDataSource,
    this.mapper = const SdkDeviceRegistryMapper(),
  });

  final SdkDevicesRemoteDataSource remoteDataSource;
  final SdkDeviceRegistryMapper mapper;

  @override
  Future<List<BackendRegisteredDevice>> listRegisteredDevices() async {
    final items = await remoteDataSource.listDevices();
    return items.map(mapper.toDomain).toList(growable: false);
  }

  @override
  Future<void> removeRegisteredDevice(String deviceId) {
    return remoteDataSource.deleteDevice(deviceId);
  }

  @override
  Future<BackendRegisteredDevice> upsertRegisteredDevice({
    required String hardwareId,
    required String firmwareVersion,
    required String hardwareModel,
    required DateTime pairedAt,
  }) async {
    final dto = await remoteDataSource.upsertDevice(
      hardwareId: hardwareId,
      firmwareVersion: firmwareVersion,
      hardwareModel: hardwareModel,
      pairedAt: pairedAt,
    );
    return mapper.toDomain(dto);
  }
}
