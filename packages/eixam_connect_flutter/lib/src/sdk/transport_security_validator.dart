import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

class SdkTransportSecurityValidator {
  const SdkTransportSecurityValidator._();

  static void validateConfig(EixamSdkConfig config) {
    validateApiBaseUrl(config);
    final realtimeUrl = config.websocketUrl?.trim();
    if (realtimeUrl != null && realtimeUrl.isNotEmpty) {
      validateRealtimeEndpoint(config, endpoint: realtimeUrl);
    }
  }

  static void validateApiBaseUrl(EixamSdkConfig config) {
    final uri = _parseUri(
      config.apiBaseUrl,
      fieldName: 'apiBaseUrl',
      code: 'E_SDK_INSECURE_API_ENDPOINT',
    );
    if (uri.scheme.toLowerCase() == 'https') {
      return;
    }
    if (_allowsInsecureLocalEndpoint(config, uri) &&
        uri.scheme.toLowerCase() == 'http') {
      return;
    }
    throw const TransportSecurityException(
      'E_SDK_INSECURE_API_ENDPOINT',
      'SDK API endpoints must use HTTPS. Insecure local HTTP is allowed only '
          'for explicit debug/test local development.',
    );
  }

  static void validateRealtimeEndpoint(
    EixamSdkConfig config, {
    required String endpoint,
  }) {
    final uri = _parseUri(
      endpoint,
      fieldName: 'websocketUrl',
      code: 'E_SDK_INSECURE_REALTIME_ENDPOINT',
    );
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'wss' || scheme == 'ssl' || scheme == 'tls') {
      return;
    }
    if (_allowsInsecureLocalEndpoint(config, uri) &&
        (scheme == 'ws' ||
            scheme == 'http' ||
            scheme == 'tcp' ||
            scheme == 'mqtt')) {
      return;
    }
    throw const TransportSecurityException(
      'E_SDK_INSECURE_REALTIME_ENDPOINT',
      'SDK realtime endpoints must use wss:// or ssl/tls MQTT transport. '
          'Insecure local realtime endpoints are allowed only for explicit '
          'debug/test local development.',
    );
  }

  static Uri _parseUri(
    String value, {
    required String fieldName,
    required String code,
  }) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw TransportSecurityException(
        code,
        'SDK transport endpoint $fieldName must not be empty.',
      );
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) {
      throw TransportSecurityException(
        code,
        'SDK transport endpoint $fieldName must be an absolute URL.',
      );
    }
    return uri;
  }

  static bool _allowsInsecureLocalEndpoint(
    EixamSdkConfig config,
    Uri uri,
  ) {
    return kDebugMode &&
        config.allowInsecureLocalEndpoints &&
        _isLocalDevelopmentHost(uri.host);
  }

  static bool _isLocalDevelopmentHost(String host) {
    final normalized = host.trim().toLowerCase();
    return normalized == 'localhost' ||
        normalized == '127.0.0.1' ||
        normalized == '::1' ||
        normalized == '[::1]' ||
        normalized == '10.0.2.2' ||
        normalized == '10.0.3.2';
  }
}
