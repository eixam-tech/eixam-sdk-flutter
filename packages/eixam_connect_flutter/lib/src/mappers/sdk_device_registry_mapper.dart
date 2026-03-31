import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/dtos/sdk_device_dto.dart';

class SdkDeviceRegistryMapper {
  const SdkDeviceRegistryMapper();

  BackendRegisteredDevice toDomain(SdkDeviceDto dto) {
    return BackendRegisteredDevice(
      id: dto.id,
      hardwareId: dto.hardwareId,
      firmwareVersion: dto.firmwareVersion,
      hardwareModel: dto.hardwareModel,
      pairedAt: DateTime.parse(dto.pairedAt).toUtc(),
      createdAt: DateTime.parse(dto.createdAt ?? dto.pairedAt).toUtc(),
      updatedAt: DateTime.parse(dto.updatedAt ?? dto.createdAt ?? dto.pairedAt)
          .toUtc(),
    );
  }
}
