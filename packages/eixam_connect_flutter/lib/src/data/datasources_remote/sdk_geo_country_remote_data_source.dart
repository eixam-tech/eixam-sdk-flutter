import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'sdk_http_transport.dart';

abstract class SdkGeoCountryRemoteDataSource {
  /// Resolves the ISO country for a physical location.
  Future<ResolvedCountry> resolveCountry({
    required double latitude,
    required double longitude,
  });
}

/// HTTP implementation for `GET /v1/sdk/geo/country`.
///
/// PROPOSED backend contract — this endpoint does not exist yet. The backend
/// team will implement `GET /v1/sdk/geo/country?lat=&lon=` returning
/// `{ "country_iso": "ES" }`. Parsing is kept lenient and isolated here so the
/// contract can evolve without touching the controller. Until it ships, callers
/// surface a "country unknown" skip rather than failing the apply.
class HttpSdkGeoCountryRemoteDataSource
    implements SdkGeoCountryRemoteDataSource {
  HttpSdkGeoCountryRemoteDataSource({required this.transport});

  static const _path = '/v1/sdk/geo/country';

  final SdkHttpTransport transport;

  @override
  Future<ResolvedCountry> resolveCountry({
    required double latitude,
    required double longitude,
  }) async {
    final path = Uri(
      path: _path,
      queryParameters: <String, String>{
        'lat': latitude.toString(),
        'lon': longitude.toString(),
      },
    ).toString();
    final response = await transport.get(
      path,
      headers: const <String, String>{'Accept': 'application/json'},
    );
    final statusCode = response.statusCode;
    if (statusCode < 200 || statusCode >= 300) {
      throw NetworkException('E_SDK_GEO_COUNTRY_FAILED', response.body);
    }
    final json = _decode(response.body);
    final iso = json['country_iso'];
    if (iso is! String || iso.trim().isEmpty) {
      throw const NetworkException(
        'E_SDK_GEO_COUNTRY_UNKNOWN',
        'E_SDK_GEO_COUNTRY_UNKNOWN',
      );
    }
    return ResolvedCountry(
      countryIso: iso.trim().toUpperCase(),
      latitude: latitude,
      longitude: longitude,
    );
  }

  Map<String, dynamic> _decode(String body) {
    if (body.trim().isEmpty) {
      return <String, dynamic>{};
    }
    final Object decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const NetworkException(
        'E_SDK_GEO_COUNTRY_INVALID_JSON',
        'E_SDK_GEO_COUNTRY_INVALID_JSON',
      );
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw const NetworkException(
      'E_SDK_GEO_COUNTRY_INVALID_JSON',
      'E_SDK_GEO_COUNTRY_INVALID_JSON',
    );
  }
}
