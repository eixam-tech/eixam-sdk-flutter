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
      id: _optionalString(json, const ['id']) ?? '',
      version: _optionalString(json, const ['version']) ?? '',
      hardwareModel: _optionalString(
        json,
        const ['hardware_model', 'hardwareModel'],
      ),
      sha256Hash: _optionalString(
        json,
        const ['sha256_hash', 'sha256Hash'],
      ),
      fileSizeBytes: _optionalInt(
        json,
        const ['file_size_bytes', 'fileSizeBytes'],
      ),
      releaseNotes: _optionalString(
        json,
        const ['release_notes', 'releaseNotes'],
      ),
      isActive: _optionalBool(json, const ['is_active', 'isActive']),
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
  const SdkFirmwareCheckDto({required this.updateAvailable, this.firmware});

  factory SdkFirmwareCheckDto.fromJson(Map<String, dynamic> json) {
    final firmwareJson = json['firmware'];
    final firmware = firmwareJson is Map<String, dynamic>
        ? SdkFirmwareDto.fromJson(firmwareJson)
        : null;
    return SdkFirmwareCheckDto(
      updateAvailable: _optionalBool(
            json,
            const ['update_available', 'updateAvailable'],
          ) ??
          (firmware != null && firmware.version.isNotEmpty),
      firmware: firmware,
    );
  }

  final bool updateAvailable;
  final SdkFirmwareDto? firmware;
}

class SdkFirmwareListDto {
  const SdkFirmwareListDto({required this.firmwareVersions});

  factory SdkFirmwareListDto.fromJson(Map<String, dynamic> json) {
    final raw = json['firmware_versions'] ?? json['firmwareVersions'];
    return SdkFirmwareListDto(
      firmwareVersions: raw is List<dynamic>
          ? <SdkFirmwareDto>[
              for (final item in raw)
                if (item is Map<String, dynamic>) SdkFirmwareDto.fromJson(item),
            ]
          : const <SdkFirmwareDto>[],
    );
  }

  final List<SdkFirmwareDto> firmwareVersions;
}

class SdkFirmwareDownloadDto {
  const SdkFirmwareDownloadDto({
    required this.downloadUrl,
    required this.sha256Hash,
    this.expiresInSeconds,
  });

  factory SdkFirmwareDownloadDto.fromJson(Map<String, dynamic> json) {
    return SdkFirmwareDownloadDto(
      downloadUrl: _optionalString(
            json,
            const ['download_url', 'downloadUrl'],
          ) ??
          '',
      sha256Hash: _optionalString(
            json,
            const ['sha256_hash', 'sha256Hash'],
          ) ??
          '',
      expiresInSeconds: _optionalInt(
        json,
        const ['expires_in_seconds', 'expiresInSeconds'],
      ),
    );
  }

  final String downloadUrl;
  final String sha256Hash;
  final int? expiresInSeconds;
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

int? _optionalInt(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
  }
  return null;
}

bool? _optionalBool(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') return true;
      if (normalized == 'false' || normalized == '0') return false;
    }
  }
  return null;
}
