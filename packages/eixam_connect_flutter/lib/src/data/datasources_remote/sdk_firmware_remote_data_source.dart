import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../dtos/sdk_firmware_dto.dart';
import 'sdk_http_transport.dart';

abstract class SdkFirmwareRemoteDataSource {
  Future<SdkFirmwareCheckDto> checkUpdate({
    required String? hardwareModel,
    required String currentVersion,
  });

  Future<SdkFirmwareDownloadDto> prepareDownload(String releaseId);

  Future<List<int>> downloadArtifact(String downloadUrl);
}

class HttpSdkFirmwareRemoteDataSource implements SdkFirmwareRemoteDataSource {
  HttpSdkFirmwareRemoteDataSource({required this.transport});

  final SdkHttpTransport transport;

  @override
  Future<SdkFirmwareCheckDto> checkUpdate({
    required String? hardwareModel,
    required String currentVersion,
  }) async {
    final query = <String, String>{
      'current_version': currentVersion,
      if (hardwareModel != null && hardwareModel.trim().isNotEmpty)
        'hardware_model': hardwareModel.trim(),
    };
    final path = Uri(
      path: '/v1/sdk/firmware/check',
      queryParameters: query,
    ).toString();
    final response = await transport.get(path);
    if (response.statusCode != 200) {
      throw FirmwareUpdateException(
        'E_FIRMWARE_CHECK_FAILED',
        response.body,
      );
    }
    return SdkFirmwareCheckDto.fromJson(
      _decode(response.body, errorCode: 'E_FIRMWARE_CHECK_INVALID_JSON'),
    );
  }

  @override
  Future<SdkFirmwareDownloadDto> prepareDownload(String releaseId) async {
    final response =
        await transport.get('/v1/sdk/firmware/download/$releaseId');
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
  Future<List<int>> downloadArtifact(String downloadUrl) async {
    final response = await transport.client.get(Uri.parse(downloadUrl));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FirmwareUpdateException(
        'E_FIRMWARE_ARTIFACT_DOWNLOAD_FAILED',
        response.body,
      );
    }
    return response.bodyBytes;
  }

  Map<String, dynamic> _decode(
    String body, {
    required String errorCode,
  }) {
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
