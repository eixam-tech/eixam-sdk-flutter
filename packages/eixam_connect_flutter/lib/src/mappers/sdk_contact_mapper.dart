import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/dtos/sdk_contact_dto.dart';

class SdkContactMapper {
  const SdkContactMapper();

  EmergencyContact toDomain(SdkContactDto dto, {DateTime? now}) {
    final stamp = now ?? DateTime.now().toUtc();
    return EmergencyContact(
      id: dto.id,
      name: dto.name,
      phone: dto.phone,
      email: dto.email,
      priority: dto.priority,
      language: dto.language,
      createdAt: _parseOptionalTimestamp(dto.createdAt) ?? stamp,
      updatedAt: _parseOptionalTimestamp(dto.updatedAt) ?? stamp,
    );
  }

  DateTime? _parseOptionalTimestamp(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    try {
      return DateTime.parse(value).toUtc();
    } on FormatException {
      return null;
    }
  }
}
