import 'package:eixam_connect_core/eixam_connect_core.dart';

class SdkFirmwareDto {
  const SdkFirmwareDto({
    required this.id,
    required this.version,
    this.hardwareModel,
    this.sha256Hash,
    this.fileSizeBytes,
    this.releaseNotes,
    this.isActive,
  });

  factory SdkFirmwareDto.fromJson(Map<String, dynamic> json) {
    return SdkFirmwareDto(
      id: (json['id'] as String?)?.trim() ?? '',
      version: (json['version'] as String?)?.trim() ?? '',
      hardwareModel: (json['hardware_model'] as String?)?.trim(),
      sha256Hash: (json['sha256_hash'] as String?)?.trim(),
      fileSizeBytes: json['file_size_bytes'] is int
          ? json['file_size_bytes'] as int
          : int.tryParse(json['file_size_bytes']?.toString() ?? ''),
      releaseNotes: json['release_notes'] as String?,
      isActive: json['is_active'] as bool?,
    );
  }

  final String id;
  final String version;
  final String? hardwareModel;
  final String? sha256Hash;
  final int? fileSizeBytes;
  final String? releaseNotes;
  final bool? isActive;

  FirmwareRelease toDomain() {
    return FirmwareRelease(
      releaseId: id,
      version: version,
      hardwareModel: hardwareModel?.isEmpty == true ? null : hardwareModel,
      sha256Hash: sha256Hash?.isEmpty == true ? null : sha256Hash,
      fileSizeBytes: fileSizeBytes,
      releaseNotes: releaseNotes,
      bootloaderType: 'nordic_adafruit_secure_dfu',
      artifactKind: 'dfu_zip',
    );
  }
}

class SdkFirmwareCheckDto {
  const SdkFirmwareCheckDto({
    required this.updateAvailable,
    this.firmware,
  });

  factory SdkFirmwareCheckDto.fromJson(Map<String, dynamic> json) {
    final firmwareJson = json['firmware'];
    return SdkFirmwareCheckDto(
      updateAvailable: json['update_available'] == true,
      firmware: firmwareJson is Map<String, dynamic>
          ? SdkFirmwareDto.fromJson(firmwareJson)
          : null,
    );
  }

  final bool updateAvailable;
  final SdkFirmwareDto? firmware;
}

class SdkFirmwareDownloadDto {
  const SdkFirmwareDownloadDto({
    required this.downloadUrl,
    required this.sha256Hash,
    this.expiresInSeconds,
  });

  factory SdkFirmwareDownloadDto.fromJson(Map<String, dynamic> json) {
    return SdkFirmwareDownloadDto(
      downloadUrl: (json['download_url'] as String?)?.trim() ?? '',
      sha256Hash: (json['sha256_hash'] as String?)?.trim() ?? '',
      expiresInSeconds: json['expires_in_seconds'] is int
          ? json['expires_in_seconds'] as int
          : int.tryParse(json['expires_in_seconds']?.toString() ?? ''),
    );
  }

  final String downloadUrl;
  final String sha256Hash;
  final int? expiresInSeconds;
}
