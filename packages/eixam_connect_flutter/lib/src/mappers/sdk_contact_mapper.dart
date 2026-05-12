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
      language: dto.language,
      createdAt: _parseRequiredTimestamp(dto.createdAt, field: 'createdAt'),
      updatedAt: _parseRequiredTimestamp(dto.updatedAt, field: 'updatedAt'),
    );
  }

  DateTime _parseRequiredTimestamp(String? value, {required String field}) {
    if (value == null || value.trim().isEmpty) {
      throw ContactsException(
        'E_HTTP_CONTACTS_INVALID_PAYLOAD',
        'E_HTTP_CONTACTS_MISSING_FIELD field=$field',
      );
    }
    try {
      return DateTime.parse(value).toUtc();
    } on FormatException {
      throw ContactsException(
        'E_HTTP_CONTACTS_INVALID_PAYLOAD',
        'E_HTTP_CONTACTS_INVALID_FIELD field=$field',
      );
    }
  }
}
