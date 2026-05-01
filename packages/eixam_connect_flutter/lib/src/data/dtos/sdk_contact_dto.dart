import 'package:eixam_connect_core/eixam_connect_core.dart';

class SdkContactDto {
  const SdkContactDto({
    required this.id,
    required this.name,
    required this.phone,
    required this.email,
    required this.priority,
    this.language = 'en',
    this.createdAt,
    this.updatedAt,
  });

  factory SdkContactDto.fromJson(Map<String, dynamic> json) {
    final language = _optionalString(json, 'language')?.trim();
    return SdkContactDto(
      id: _requiredString(json, 'id'),
      name: _requiredString(json, 'name'),
      phone: _requiredString(json, 'phone'),
      email: _requiredString(json, 'email'),
      priority: _requiredInt(json, 'priority'),
      language: language == null || language.isEmpty ? 'en' : language,
      createdAt: _optionalString(json, 'createdAt') ??
          _optionalString(json, 'created_at'),
      updatedAt: _optionalString(json, 'updatedAt') ??
          _optionalString(json, 'updated_at'),
    );
  }

  final String id;
  final String name;
  final String phone;
  final String email;
  final int priority;
  final String language;
  final String? createdAt;
  final String? updatedAt;

  static String _requiredString(Map<String, dynamic> json, String field) {
    final value = json[field];
    if (value is String && value.trim().isNotEmpty) {
      return value;
    }
    throw ContactsException(
      'E_HTTP_CONTACTS_INVALID_PAYLOAD',
      'The backend contact payload has an invalid $field.',
    );
  }

  static String? _optionalString(Map<String, dynamic> json, String field) {
    final value = json[field];
    if (value == null) {
      return null;
    }
    if (value is String) {
      return value;
    }
    throw ContactsException(
      'E_HTTP_CONTACTS_INVALID_PAYLOAD',
      'The backend contact payload has an invalid $field.',
    );
  }

  static int _requiredInt(Map<String, dynamic> json, String field) {
    final value = json[field];
    if (value is int) {
      return value;
    }
    if (value is num && value % 1 == 0) {
      return value.toInt();
    }
    throw ContactsException(
      'E_HTTP_CONTACTS_INVALID_PAYLOAD',
      'The backend contact payload has an invalid $field.',
    );
  }
}
