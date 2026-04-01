import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/dtos/sdk_contact_dto.dart';

class SdkContactMapper {
  const SdkContactMapper();

  EmergencyContact toDomain(SdkContactDto dto) {
    return EmergencyContact(
      id: dto.id,
      name: dto.name,
      phone: dto.phone,
      email: dto.email,
      priority: dto.priority,
      createdAt: DateTime.parse(
        dto.createdAt ??
            DateTime.fromMillisecondsSinceEpoch(0).toIso8601String(),
      ).toUtc(),
      updatedAt: DateTime.parse(
        dto.updatedAt ??
            dto.createdAt ??
            DateTime.fromMillisecondsSinceEpoch(0).toIso8601String(),
      ).toUtc(),
    );
  }
}
