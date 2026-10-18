import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../activity_availability_parser.dart';
import 'sdk_http_transport.dart';

abstract interface class SdkActivityAvailabilityRemoteDataSource {
  Future<List<SdkAvailableActivity>> fetch(
    EixamSession session, {
    required String backend,
  });
}

final class HttpSdkActivityAvailabilityRemoteDataSource
    implements SdkActivityAvailabilityRemoteDataSource {
  HttpSdkActivityAvailabilityRemoteDataSource({required this.transport});

  final SdkHttpTransport transport;

  @override
  Future<List<SdkAvailableActivity>> fetch(
    EixamSession session, {
    required String backend,
  }) async {
    // Production transports have fixed endpoints. Reinitializing a runtime must
    // never put an old backend's response into a new backend's cache scope.
    String normalized(String url) => url.replaceFirst(RegExp(r'/+$'), '');
    if (normalized(backend) != normalized(transport.config.apiBaseUrl)) {
      throw const ActivityAvailabilityException(
        'E_ACTIVITY_AVAILABILITY_UNAVAILABLE',
        'Bootstrap a new SDK instance to change the availability backend.',
      );
    }
    final response = await transport.get(
      '/v1/sdk/activities',
      sessionOverride: session,
      headers: const {'Accept': 'application/json'},
    );
    if (response.statusCode == 401) {
      throw const AuthException(
        'E_ACTIVITY_AVAILABILITY_UNAUTHORIZED',
        'The SDK identity was rejected.',
      );
    }
    if (response.statusCode != 200) {
      throw NetworkException(
        response.statusCode == 429
            ? 'E_ACTIVITY_AVAILABILITY_RATE_LIMITED'
            : 'E_ACTIVITY_AVAILABILITY_HTTP_FAILED',
        'Activity availability request failed (HTTP ${response.statusCode}).',
      );
    }
    try {
      return parseAvailableActivities(jsonDecode(response.body));
    } on FormatException {
      throw const ActivityAvailabilityException(
        'E_ACTIVITY_AVAILABILITY_INVALID_RESPONSE',
        'The backend returned an invalid activity assignment snapshot.',
      );
    }
  }
}
