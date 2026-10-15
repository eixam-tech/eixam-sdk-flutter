import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

import '../data/datasources_remote/sdk_firmware_remote_data_source.dart';
import '../data/dtos/sdk_firmware_dto.dart';

/// Both explicit flags and a debug binary are required. Release/profile never
/// construct a candidate source, even when supplied a QA configuration file.
bool frozenQaFirmwareEnabled({
  required bool debugBuild,
  required bool physicalQa,
  required bool candidateEnabled,
}) => debugBuild && physicalQa && candidateEnabled;

SdkFirmwareRemoteDataSource composeFirmwareSource(
  SdkFirmwareRemoteDataSource normal,
) {
  const requested = bool.fromEnvironment('EIXAM_QA_FIRMWARE');
  const physicalQa = bool.fromEnvironment('EIXAM_PHYSICAL_QA');
  if (!frozenQaFirmwareEnabled(
    debugBuild: kDebugMode,
    physicalQa: physicalQa,
    candidateEnabled: requested,
  )) {
    return normal;
  }
  const sourceSha = String.fromEnvironment('EIXAM_QA_FIRMWARE_SHA');
  const version = String.fromEnvironment('EIXAM_QA_FIRMWARE_VERSION');
  const model = String.fromEnvironment('EIXAM_QA_FIRMWARE_MODEL');
  const hash = String.fromEnvironment('EIXAM_QA_FIRMWARE_ZIP_SHA256');
  const size = int.fromEnvironment('EIXAM_QA_FIRMWARE_ZIP_BYTES');
  final source = FrozenQaFirmwareSource(
    sourceSha: sourceSha,
    expectedLiveVersion: version,
    hardwareModel: model,
    artifactSha256: hash,
    artifactSizeBytes: size,
  );
  debugPrint(
    'QA_CANDIDATE_CATALOG_ACTIVE=YES firmwareSha=$sourceSha '
    'target=$model expectedLiveVersion=$version ZIP_SHA256=$hash '
    'verificationPolicy=exactCandidate',
  );
  return source;
}

/// One immutable QA release. No HTTP or remote fallback. The shared
/// coordinator reads and verifies a preseeded artifact using its normal cache.
final class FrozenQaFirmwareSource extends SdkFirmwareRemoteDataSource {
  FrozenQaFirmwareSource({
    required String sourceSha,
    required String expectedLiveVersion,
    required String hardwareModel,
    required String artifactSha256,
    required int artifactSizeBytes,
  }) : release = SdkFirmwareDto(
         id: 'physical-qa-$sourceSha-$artifactSha256',
         version: expectedLiveVersion,
         hardwareModel: hardwareModel,
         sha256Hash: artifactSha256,
         fileSizeBytes: artifactSizeBytes,
         isActive: true,
         verificationPolicy: FirmwareVerificationPolicy.exactCandidate,
       ) {
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(sourceSha) ||
        expectedLiveVersion.isEmpty ||
        expectedLiveVersion.trim() != expectedLiveVersion ||
        expectedLiveVersion.toLowerCase() == 'unknown' ||
        hardwareModel.trim().isEmpty ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(artifactSha256) ||
        artifactSizeBytes <= 0 ||
        artifactSizeBytes > maxFirmwareArtifactBytes) {
      throw const FirmwareUpdateException(
        'invalidFrozenQaCandidate',
        'Frozen QA configuration or artifact integrity is invalid.',
      );
    }
  }

  final SdkFirmwareDto release;
  static const _artifactUrl = 'physical-qa:verified-dfu-zip';

  bool _matches(String? model) =>
      model?.trim().toLowerCase() == release.hardwareModel!.toLowerCase();

  @override
  Future<SdkFirmwareListDto> listReleases({
    required String? hardwareModel,
  }) async => SdkFirmwareListDto(
    firmwareVersions: _matches(hardwareModel) ? [release] : [],
  );

  @override
  Future<SdkFirmwareCheckDto> checkUpdate({
    required String? hardwareModel,
    required String currentVersion,
    bool allowDowngrade = false,
    String? targetReleaseId,
  }) async {
    final selected =
        _matches(hardwareModel) &&
        (targetReleaseId == null || targetReleaseId == release.id);
    return SdkFirmwareCheckDto(
      updateAvailable: selected && currentVersion != release.version,
      firmware: selected ? release : null,
    );
  }

  @override
  Future<SdkFirmwareDownloadDto> prepareDownload(String releaseId) async {
    if (releaseId != release.id) {
      throw const FirmwareUpdateException(
        'artifactMissing',
        'Unknown QA release.',
      );
    }
    return SdkFirmwareDownloadDto(
      downloadUrl: _artifactUrl,
      sha256Hash: release.sha256Hash!,
    );
  }

  @override
  Future<List<int>> downloadArtifact(
    String downloadUrl, {
    int? expectedSizeBytes,
    int maxSizeBytes = maxFirmwareArtifactBytes,
    int sizeToleranceBytes = firmwareArtifactSizeToleranceBytes,
  }) async {
    throw const FirmwareUpdateException(
      'qaArtifactNotPreseeded',
      'The frozen QA artifact must be preseeded in the SDK verified cache.',
    );
  }
}
