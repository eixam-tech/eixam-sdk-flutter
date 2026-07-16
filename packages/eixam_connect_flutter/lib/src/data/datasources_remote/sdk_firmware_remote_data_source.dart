import 'dart:convert';
import 'dart:typed_data';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:http/http.dart' as http;

import '../dtos/sdk_firmware_dto.dart';
import 'sdk_http_transport.dart';

const int maxFirmwareArtifactBytes = 16 * 1024 * 1024;
const int firmwareArtifactSizeToleranceBytes = 0;
const String firmwareArtifactTooLargeCode = 'E_FIRMWARE_ARTIFACT_TOO_LARGE';

abstract class SdkFirmwareRemoteDataSource {
  Future<SdkFirmwareCheckDto> checkUpdate({
    required String? hardwareModel,
    required String currentVersion,
    bool allowDowngrade = false,
    String? targetReleaseId,
  });

  Future<SdkFirmwareListDto> listReleases({required String? hardwareModel});

  Future<SdkFirmwareDownloadDto> prepareDownload(String releaseId);

  Future<List<int>> downloadArtifact(
    String downloadUrl, {
    int? expectedSizeBytes,
    int maxSizeBytes = maxFirmwareArtifactBytes,
    int sizeToleranceBytes = firmwareArtifactSizeToleranceBytes,
  });
}

class HttpSdkFirmwareRemoteDataSource implements SdkFirmwareRemoteDataSource {
  HttpSdkFirmwareRemoteDataSource({required this.transport});

  final SdkHttpTransport transport;

  @override
  Future<SdkFirmwareCheckDto> checkUpdate({
    required String? hardwareModel,
    required String currentVersion,
    bool allowDowngrade = false,
    String? targetReleaseId,
  }) async {
    final query = <String, String>{
      'current_version': currentVersion,
      if (allowDowngrade) 'allow_downgrade': 'true',
      if (targetReleaseId != null && targetReleaseId.trim().isNotEmpty)
        'target_release_id': targetReleaseId.trim(),
      if (hardwareModel != null && hardwareModel.trim().isNotEmpty)
        'hardware_model': hardwareModel.trim(),
    };
    // Encode values with %20 for spaces (Uri.queryParameters emits `+`, which
    // some backends do not decode back to a space — a hardware model like
    // "EIXAM R1" would then miss its release).
    final encodedQuery = query.entries
        .map(
          (entry) =>
            '${Uri.encodeQueryComponent(entry.key)}='
              '${Uri.encodeComponent(entry.value)}',
        )
        .join('&');
    final path = '/v1/sdk/firmware/check?$encodedQuery';
    final response = await transport.get(path);
    if (response.statusCode != 200) {
      throw FirmwareUpdateException('E_FIRMWARE_CHECK_FAILED', response.body);
    }
    return SdkFirmwareCheckDto.fromJson(
      _decode(response.body, errorCode: 'E_FIRMWARE_CHECK_INVALID_JSON'),
    );
  }

  @override
  Future<SdkFirmwareListDto> listReleases({
    required String? hardwareModel,
  }) async {
    final query = <String, String>{
      if (hardwareModel != null && hardwareModel.trim().isNotEmpty)
        'hardware_model': hardwareModel.trim(),
    };
    final encodedQuery = query.entries
        .map(
          (entry) =>
              '${Uri.encodeQueryComponent(entry.key)}='
              '${Uri.encodeComponent(entry.value)}',
        )
        .join('&');
    final path = encodedQuery.isEmpty
        ? '/v1/sdk/firmware/releases'
        : '/v1/sdk/firmware/releases?$encodedQuery';
    final response = await transport.get(path);
    if (response.statusCode != 200) {
      throw FirmwareUpdateException('E_FIRMWARE_LIST_FAILED', response.body);
    }
    return SdkFirmwareListDto.fromJson(
      _decode(response.body, errorCode: 'E_FIRMWARE_LIST_INVALID_JSON'),
    );
  }

  @override
  Future<SdkFirmwareDownloadDto> prepareDownload(String releaseId) async {
    final response = await transport.get(
      '/v1/sdk/firmware/download/$releaseId',
    );
    if (response.statusCode != 200) {
      throw FirmwareUpdateException(
        'E_FIRMWARE_DOWNLOAD_PREPARE_FAILED',
        response.body,
      );
    }
    return SdkFirmwareDownloadDto.fromJson(
      _decode(
        response.body,
        errorCode: 'E_FIRMWARE_DOWNLOAD_PREPARE_INVALID_JSON',
      ),
    );
  }

  @override
  Future<List<int>> downloadArtifact(
    String downloadUrl, {
    int? expectedSizeBytes,
    int maxSizeBytes = maxFirmwareArtifactBytes,
    int sizeToleranceBytes = firmwareArtifactSizeToleranceBytes,
  }) async {
    final request = http.Request('GET', Uri.parse(downloadUrl));
    final response = await transport.client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errorBody = await response.stream.bytesToString();
      throw FirmwareUpdateException(
        'E_FIRMWARE_ARTIFACT_DOWNLOAD_FAILED',
        errorBody,
      );
    }
    _validateFirmwareArtifactSize(
      contentLength: response.contentLength,
      expectedSizeBytes: expectedSizeBytes,
      maxSizeBytes: maxSizeBytes,
      sizeToleranceBytes: sizeToleranceBytes,
      phase: 'contentLength',
    );

    final builder = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in response.stream) {
      received += chunk.length;
      _validateFirmwareArtifactSize(
        actualSizeBytes: received,
        expectedSizeBytes: expectedSizeBytes,
        maxSizeBytes: maxSizeBytes,
        sizeToleranceBytes: sizeToleranceBytes,
        phase: 'download',
      );
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    _validateFirmwareArtifactSize(
      actualSizeBytes: bytes.length,
      expectedSizeBytes: expectedSizeBytes,
      maxSizeBytes: maxSizeBytes,
      sizeToleranceBytes: sizeToleranceBytes,
      phase: 'body',
    );
    return bytes;
  }

  Map<String, dynamic> _decode(String body, {required String errorCode}) {
    final Object decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw FirmwareUpdateException(errorCode, errorCode);
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw FirmwareUpdateException(errorCode, errorCode);
  }
}

void validateFirmwareArtifactMetadataSize(
  int? fileSizeBytes, {
  int maxSizeBytes = maxFirmwareArtifactBytes,
  int sizeToleranceBytes = firmwareArtifactSizeToleranceBytes,
}) {
  if (fileSizeBytes == null) {
    return;
  }
  _validateFirmwareArtifactSize(
    actualSizeBytes: fileSizeBytes,
    maxSizeBytes: maxSizeBytes,
    sizeToleranceBytes: sizeToleranceBytes,
    phase: 'metadata',
  );
}

void validateFirmwareArtifactDownloadedSize(
  int actualSizeBytes, {
  int? expectedSizeBytes,
  int maxSizeBytes = maxFirmwareArtifactBytes,
  int sizeToleranceBytes = firmwareArtifactSizeToleranceBytes,
}) {
  _validateFirmwareArtifactSize(
    actualSizeBytes: actualSizeBytes,
    expectedSizeBytes: expectedSizeBytes,
    maxSizeBytes: maxSizeBytes,
    sizeToleranceBytes: sizeToleranceBytes,
    phase: 'body',
  );
}

void _validateFirmwareArtifactSize({
  int? contentLength,
  int? actualSizeBytes,
  int? expectedSizeBytes,
  required int maxSizeBytes,
  required int sizeToleranceBytes,
  required String phase,
}) {
  final observed = contentLength ?? actualSizeBytes;
  if (observed == null) {
    return;
  }
  if (observed < 0) {
    throw const FirmwareUpdateException(
      firmwareArtifactTooLargeCode,
      'Firmware artifact size metadata is invalid.',
    );
  }
  final toleratedExpected = expectedSizeBytes == null
      ? null
      : expectedSizeBytes + sizeToleranceBytes;
  if (toleratedExpected != null && observed > toleratedExpected) {
    throw FirmwareUpdateException(
      firmwareArtifactTooLargeCode,
      'Firmware artifact $phase size exceeds expected metadata.',
    );
  }
  if (observed > maxSizeBytes) {
    throw FirmwareUpdateException(
      firmwareArtifactTooLargeCode,
      'Firmware artifact $phase size exceeds SDK limit.',
    );
  }
}
