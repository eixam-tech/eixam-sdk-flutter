class SdkDeviceDto {
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

  factory SdkDeviceDto.fromJson(Map<String, dynamic> json) {
    return SdkDeviceDto(
      id: json['id'] as String,
      hardwareId: json['hardware_id'] as String,
      firmwareVersion: json['firmware_version'] as String,
      hardwareModel: json['hardware_model'] as String,
      pairedAt: json['paired_at'] as String,
      createdAt: json['created_at'] as String?,
      updatedAt: json['updated_at'] as String?,
    );
  }
}
