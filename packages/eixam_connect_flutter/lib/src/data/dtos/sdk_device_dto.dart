class SdkDeviceDto {
  factory SdkDeviceDto.fromJson(Map<String, dynamic> json) {
    return SdkDeviceDto(
      id: _requiredString(json, const ['id']) ??
          _requiredString(json, const ['hardware_id', 'hardwareId']) ??
          (throw const FormatException('Missing id')),
      hardwareId: _requiredString(json, const ['hardware_id', 'hardwareId']) ??
          (throw const FormatException('Missing hardware_id')),
      firmwareVersion: _optionalString(
            json,
            const ['firmware_version', 'firmwareVersion'],
          ) ??
          'unknown',
      hardwareModel: _optionalString(
            json,
            const ['hardware_model', 'hardwareModel'],
          ) ??
          'EIXAM R1',
      pairedAt: _optionalString(json, const ['paired_at', 'pairedAt']) ??
          DateTime.now().toUtc().toIso8601String(),
      createdAt: _optionalString(json, const ['created_at', 'createdAt']),
      updatedAt: _optionalString(json, const ['updated_at', 'updatedAt']),
    );
  }
  const SdkDeviceDto({
    required this.id,
    required this.hardwareId,
    required this.firmwareVersion,
    required this.hardwareModel,
    required this.pairedAt,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String hardwareId;
  final String firmwareVersion;
  final String hardwareModel;
  final String pairedAt;
  final String? createdAt;
  final String? updatedAt;
}

String? _requiredString(Map<String, dynamic> json, List<String> keys) {
  return _optionalString(json, keys);
}

String? _optionalString(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
    if (value is num) {
      return value.toInt().toString();
    }
  }
  return null;
}
