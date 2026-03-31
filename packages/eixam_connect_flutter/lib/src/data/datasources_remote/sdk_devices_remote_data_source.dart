import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../dtos/sdk_device_dto.dart';
import 'sdk_http_transport.dart';

abstract class SdkDevicesRemoteDataSource {
  Future<SdkDeviceDto> upsertDevice({
    required String hardwareId,
    required String firmwareVersion,
    required String hardwareModel,
    required DateTime pairedAt,
  });

  Future<List<SdkDeviceDto>> listDevices();
  Future<void> deleteDevice(String deviceId);
}

class HttpSdkDevicesRemoteDataSource implements SdkDevicesRemoteDataSource {
  HttpSdkDevicesRemoteDataSource({required this.transport});

  final SdkHttpTransport transport;

  @override
  Future<SdkDeviceDto> upsertDevice({
    required String hardwareId,
    required String firmwareVersion,
    required String hardwareModel,
    required DateTime pairedAt,
  }) async {
    final response = await transport.post(
      '/v1/sdk/devices',
      body: jsonEncode(<String, dynamic>{
        'hardware_id': hardwareId,
        'firmware_version': firmwareVersion,
        'hardware_model': hardwareModel,
        'paired_at': pairedAt.toUtc().toIso8601String(),
      }),
    );
    if (response.statusCode != 200) {
      throw DeviceException('E_HTTP_DEVICE_UPSERT_FAILED', response.body);
    }
    final payload = _decode(response.body, errorCode: 'E_HTTP_DEVICE_UPSERT_FAILED');
    final device = payload['device'];
    if (device is! Map<String, dynamic>) {
      throw const DeviceException(
        'E_HTTP_DEVICE_UPSERT_FAILED',
        'The backend did not return a valid device payload.',
      );
    }
    return SdkDeviceDto.fromJson(device);
  }

  @override
  Future<List<SdkDeviceDto>> listDevices() async {
    final response = await transport.get('/v1/sdk/devices');
    if (response.statusCode != 200) {
      throw DeviceException('E_HTTP_DEVICE_LIST_FAILED', response.body);
    }
    final payload = _decode(response.body, errorCode: 'E_HTTP_DEVICE_LIST_FAILED');
    final devices = payload['devices'];
    if (devices is! List) {
      throw const DeviceException(
        'E_HTTP_DEVICE_LIST_FAILED',
        'The backend did not return a valid device list.',
      );
    }
    return devices
        .whereType<Map<String, dynamic>>()
        .map(SdkDeviceDto.fromJson)
        .toList(growable: false);
  }

  @override
  Future<void> deleteDevice(String deviceId) async {
    final response = await transport.client.delete(
      Uri.parse('${transport.config.apiBaseUrl}/v1/sdk/devices/$deviceId'),
      headers: transport.headersForCurrentSession(),
    );
    if (response.statusCode != 204) {
      throw DeviceException('E_HTTP_DEVICE_DELETE_FAILED', response.body);
    }
  }

  Map<String, dynamic> _decode(
    String body, {
    required String errorCode,
  }) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    throw DeviceException(errorCode, 'The backend returned invalid JSON.');
  }
}
