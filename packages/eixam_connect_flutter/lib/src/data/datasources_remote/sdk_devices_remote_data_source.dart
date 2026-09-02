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
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DeviceException('E_HTTP_DEVICE_UPSERT_FAILED', response.body);
    }
    if (response.body.trim().isEmpty) {
      return SdkDeviceDto(
        id: hardwareId,
        hardwareId: hardwareId,
        firmwareVersion: firmwareVersion,
        hardwareModel: hardwareModel,
        pairedAt: pairedAt.toUtc().toIso8601String(),
      );
    }
    try {
      final payload =
          _decode(response.body, errorCode: 'E_HTTP_DEVICE_UPSERT_FAILED');
      final device = _deviceObject(payload);
      if (device != null) {
        return SdkDeviceDto.fromJson(device);
      }
    } catch (_) {
      // 2xx means the backend accepted the assignment even if the body
      // is a shape we do not fully understand.
    }
    return SdkDeviceDto(
      id: hardwareId,
      hardwareId: hardwareId,
      firmwareVersion: firmwareVersion,
      hardwareModel: hardwareModel,
      pairedAt: pairedAt.toUtc().toIso8601String(),
    );
  }

  @override
  Future<List<SdkDeviceDto>> listDevices() async {
    final response = await transport.get('/v1/sdk/devices');
    if (response.statusCode != 200) {
      throw DeviceException('E_HTTP_DEVICE_LIST_FAILED', response.body);
    }
    final payload =
        _decode(response.body, errorCode: 'E_HTTP_DEVICE_LIST_FAILED');
    final devices = _deviceList(payload);
    if (devices == null) {
      throw const DeviceException(
        'E_HTTP_DEVICE_LIST_FAILED',
        'E_HTTP_DEVICE_INVALID_LIST_PAYLOAD',
      );
    }
    final parsed = <SdkDeviceDto>[];
    for (final device in devices) {
      if (device is! Map<String, dynamic>) {
        continue;
      }
      try {
        parsed.add(SdkDeviceDto.fromJson(device));
      } on FormatException {
        continue;
      }
    }
    return parsed;
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
    final Object decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw DeviceException(errorCode, 'E_HTTP_DEVICE_INVALID_JSON');
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw DeviceException(errorCode, 'E_HTTP_DEVICE_INVALID_JSON');
  }

  Map<String, dynamic>? _deviceObject(Map<String, dynamic> payload) {
    final device = payload['device'];
    if (device is Map<String, dynamic>) {
      return device;
    }
    final data = payload['data'];
    if (data is Map<String, dynamic>) {
      final nested = data['device'];
      if (nested is Map<String, dynamic>) {
        return nested;
      }
      if (data['hardware_id'] != null || data['hardwareId'] != null) {
        return data;
      }
    }
    if (payload['hardware_id'] != null || payload['hardwareId'] != null) {
      return payload;
    }
    return null;
  }

  List<dynamic>? _deviceList(Map<String, dynamic> payload) {
    final devices = payload['devices'] ?? payload['data'];
    if (devices is List) {
      return devices;
    }
    return null;
  }
}
