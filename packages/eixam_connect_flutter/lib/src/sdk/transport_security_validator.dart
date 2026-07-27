import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

import '../device/ble_debug_registry.dart';

enum SdkBuildMode {
  debug,
  profile,
  release;

  static SdkBuildMode get current {
    if (kDebugMode) {
      return SdkBuildMode.debug;
    }
    if (kProfileMode) {
      return SdkBuildMode.profile;
    }
    return SdkBuildMode.release;
  }

  bool get allowsInsecureEndpoints => this == SdkBuildMode.debug;
}

class SdkTransportSecurityValidator {
  const SdkTransportSecurityValidator._();

  static void validateConfig(
    EixamSdkConfig config, {
    SdkBuildMode? buildMode,
  }) {
    final resolvedBuildMode = buildMode ?? SdkBuildMode.current;
    validateApiBaseUrl(config, buildMode: resolvedBuildMode);
    final realtimeUrl = config.websocketUrl?.trim();
    if (realtimeUrl != null && realtimeUrl.isNotEmpty) {
      validateRealtimeEndpoint(
        config,
        endpoint: realtimeUrl,
        buildMode: resolvedBuildMode,
      );
    }
  }

  static void validateApiBaseUrl(
    EixamSdkConfig config, {
    SdkBuildMode? buildMode,
  }) {
    final resolvedBuildMode = buildMode ?? SdkBuildMode.current;
    final uri = _parseUri(
      config.apiBaseUrl,
      fieldName: 'apiBaseUrl',
      code: 'E_SDK_INSECURE_API_ENDPOINT',
    );
    if (uri.scheme.toLowerCase() == 'https') {
      _logAccepted(fieldName: 'apiBaseUrl', uri: uri);
      return;
    }
    if (_allowsInsecureLocalEndpoint(config, uri, resolvedBuildMode) &&
        uri.scheme.toLowerCase() == 'http') {
      _logDebugAllowed(fieldName: 'apiBaseUrl', uri: uri);
      return;
    }
    _logRejected(fieldName: 'apiBaseUrl', uri: uri);
    safeSdkDebugPrint('SDK_CONFIG_BLOCKED reason=insecure_endpoint');
    throw const TransportSecurityException(
      'E_SDK_INSECURE_API_ENDPOINT',
      'SDK API endpoints must use HTTPS. Insecure local HTTP is allowed only '
          'for explicit debug/test local development.',
    );
  }

  static void validateRealtimeEndpoint(
    EixamSdkConfig config, {
    required String endpoint,
    SdkBuildMode? buildMode,
  }) {
    final resolvedBuildMode = buildMode ?? SdkBuildMode.current;
    final uri = _parseUri(
      endpoint,
      fieldName: 'websocketUrl',
      code: 'E_SDK_INSECURE_REALTIME_ENDPOINT',
    );
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'wss' || scheme == 'ssl' || scheme == 'tls') {
      _logAccepted(fieldName: 'websocketUrl', uri: uri);
      return;
    }
    if (_allowsInsecureLocalEndpoint(config, uri, resolvedBuildMode) &&
        (scheme == 'ws' ||
            scheme == 'http' ||
            scheme == 'tcp' ||
            scheme == 'mqtt')) {
      _logDebugAllowed(fieldName: 'websocketUrl', uri: uri);
      return;
    }
    _logRejected(fieldName: 'websocketUrl', uri: uri);
    safeSdkDebugPrint('SDK_CONFIG_BLOCKED reason=insecure_endpoint');
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
    SdkBuildMode buildMode,
  ) {
    return buildMode.allowsInsecureEndpoints &&
        config.allowInsecureLocalEndpoints &&
        _isLocalDevelopmentHost(uri.host);
  }

  static void _logAccepted({required String fieldName, required Uri uri}) {
    safeSdkDebugPrint(
      'CONFIG_ENDPOINT_SECURITY_ACCEPTED '
      'field=$fieldName endpoint=${_redactUri(uri)} source=sdk',
    );
  }

  static void _logDebugAllowed({required String fieldName, required Uri uri}) {
    safeSdkDebugPrint(
      'CONFIG_ENDPOINT_SECURITY_DEBUG_INSECURE_ALLOWED '
      'field=$fieldName endpoint=${_redactUri(uri)} source=sdk',
    );
  }

  static void _logRejected({required String fieldName, required Uri uri}) {
    safeSdkDebugPrint(
      'CONFIG_ENDPOINT_SECURITY_REJECTED '
      'reason=insecure_endpoint field=$fieldName '
      'endpoint=${_redactUri(uri)} source=sdk',
    );
  }

  static String _redactUri(Uri uri) {
    final redacted = Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    );
    return redacted.toString();
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
