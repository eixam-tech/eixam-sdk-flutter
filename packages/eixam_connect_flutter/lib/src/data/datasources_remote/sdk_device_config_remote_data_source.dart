import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'sdk_http_transport.dart';

abstract class SdkDeviceConfigRemoteDataSource {
  /// Fetches the per-country device radio config. When [countryIso] is null or
  /// blank the backend resolves its `"default"` config.
  Future<DeviceCountryConfig> fetchByCountry({String? countryIso});
}

/// HTTP implementation for `GET /v1/sdk/device-configs`.
///
/// The response is free-form (`additionalProperties: true`); parsing is lenient
/// and the full payload is preserved via [DeviceCountryConfig.raw].
class HttpSdkDeviceConfigRemoteDataSource
    implements SdkDeviceConfigRemoteDataSource {
  HttpSdkDeviceConfigRemoteDataSource({required this.transport});

  static const _path = '/v1/sdk/device-configs';

  final SdkHttpTransport transport;

  @override
  Future<DeviceCountryConfig> fetchByCountry({String? countryIso}) async {
    final iso = countryIso?.trim() ?? '';
    final path = Uri(
      path: _path,
      queryParameters: <String, String>{
        if (iso.isNotEmpty) 'country_iso': iso,
      },
    ).toString();
    final response = await transport.get(
      path,
      headers: const <String, String>{'Accept': 'application/json'},
    );
    final statusCode = response.statusCode;
    // 404 = no config for this country and no configured default. Treat as
    // "no applicable region" (caller skips) rather than an error.
    if (statusCode == 404) {
      return const DeviceCountryConfig();
    }
    if (statusCode < 200 || statusCode >= 300) {
      throw NetworkException('E_SDK_DEVICE_CONFIG_FAILED', response.body);
    }
    return DeviceCountryConfig.fromJson(
      _decode(response.body, errorCode: 'E_SDK_DEVICE_CONFIG_INVALID_JSON'),
    );
  }

  Map<String, dynamic> _decode(String body, {required String errorCode}) {
    if (body.trim().isEmpty) {
      return <String, dynamic>{};
    }
    final Object decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw NetworkException(errorCode, errorCode);
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw NetworkException(errorCode, errorCode);
  }
}
