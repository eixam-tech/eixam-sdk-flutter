import 'dart:convert';

class SecurityDiagnosticsRedactor {
  const SecurityDiagnosticsRedactor._();

  static const String redacted = '<redacted>';
  static const String redactedBody = '<redacted-body>';
  static const String redactedPayload = '<redacted-payload>';
  static const String redactedTopic = '<redacted-topic>';

  static String formatHexPayloadForDiagnostics(
    String? value, {
    required bool allowSensitive,
  }) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) {
      return 'none';
    }
    if (allowSensitive) {
      return normalized;
    }
    return _redactedHexSummary(normalized);
  }

  static String formatIdentifierForDiagnostics(
    Object? value, {
    required bool allowSensitive,
  }) {
    final normalized = value?.toString().trim();
    if (normalized == null || normalized.isEmpty) {
      return 'none';
    }
    if (allowSensitive) {
      return normalized;
    }
    return redacted;
  }

  static String formatCoordinateForDiagnostics(
    num? value, {
    required bool allowSensitive,
  }) {
    if (value == null || !value.isFinite) {
      return 'none';
    }
    if (allowSensitive) {
      return value.toString();
    }
    return redacted;
  }

  static String sanitizeEventMessage(
    String message, {
    required bool allowSensitive,
  }) {
    if (allowSensitive) {
      return message;
    }
    var sanitized = message;
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b(payloadHex|rawHex|raw|packet|payload)=((?:[0-9a-fA-F]{2}(?:[\s:,-]+(?=[0-9a-fA-F]{2}(?:[\s:,-]|$)))?)+)',
      ),
      (match) => '${match[1]}=${_redactedHexSummary(match[2] ?? '')}',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'\b(body|responseBody|responseSummary|message)=\{[^}]*\}'),
      (match) => '${match[1]}=$redactedBody',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'\b(payload|body)=\[[^\]]*\]'),
      (match) => '${match[1]}=$redactedBody',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'\b(topic|endpoint)=(sos|telemetry|events|users?)/\S+'),
      (match) => '${match[1]}=$redactedTopic',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'\b(uri|brokerUri|server)=\S+'),
      (match) => '${match[1]}=$redacted',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b(X-App-ID|X-User-ID|appId|userId|sdkUserId|externalUserId|device|gateway|remote|deviceId|normalizedDeviceId|invalidBackendDeviceId|backendDeviceId|relayDeviceId|hardwareId|relayHardwareId|registeredHardwareId|runtimeDeviceId|backendHardwareId|bleHardwareId|logicalId|incidentId|canonicalIncidentId|backendIncidentId|responseIncidentId|cycleKey|signature|boundDeviceId|activeBleHardwareId)=([^\s]+)',
      ),
      (match) => '${match[1]}=$redacted',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b(nodeId|originatorNodeId|relayNodeId|strictConnectedBleNodeId|connectedBleNodeId|boundNodeId|packetId|lastOpcode|opcode|subcode)=([^\s]+)',
      ),
      (match) => '${match[1]}=$redacted',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b(lat|lon|lng|latitude|longitude|previousLat|previousLon|newLat|newLon)=(-?\d+(?:\.\d+)?)',
      ),
      (match) => '${match[1]}=$redacted',
    );
    return sanitized;
  }

  static String compactJsonForDiagnostics(
    String payload, {
    required bool allowSensitive,
  }) {
    if (!allowSensitive) {
      return jsonSummary(payload);
    }
    try {
      return jsonEncode(redactJsonValue(jsonDecode(payload)));
    } catch (_) {
      return compactSummary(payload);
    }
  }

  static String jsonSummary(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map) {
        final keys = decoded.keys.map((key) => key.toString()).toList()..sort();
        return '<json keys=${keys.join(',')}>';
      }
      if (decoded is List) {
        return '<json-list length=${decoded.length}>';
      }
    } catch (_) {
      // Fall through to a bounded non-JSON summary.
    }
    return compactSummary(payload);
  }

  static Object? redactJsonValue(Object? value, {String? key}) {
    final normalizedKey = key?.toLowerCase();
    if (normalizedKey != null) {
      if (_isSensitiveJsonKey(normalizedKey)) {
        return redacted;
      }
      if (_isLocationJsonKey(normalizedKey)) {
        return redacted;
      }
    }
    if (value is Map) {
      return value.map<String, Object?>(
        (key, child) => MapEntry(
          key.toString(),
          redactJsonValue(child, key: key.toString()),
        ),
      );
    }
    if (value is List) {
      return value.map((child) => redactJsonValue(child)).toList();
    }
    return value;
  }

  static String compactSummary(Object? value, {int maxLength = 160}) {
    final summary = value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (summary.isEmpty) {
      return 'none';
    }
    return summary.length <= maxLength
        ? summary
        : '${summary.substring(0, maxLength)}...';
  }

  static String _redactedHexSummary(String value) {
    final hexDigits = value.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    final byteCount = hexDigits.length ~/ 2;
    return byteCount > 0 ? '<redacted-hex bytes=$byteCount>' : redactedPayload;
  }

  static bool _isSensitiveJsonKey(String key) {
    return key.contains('token') ||
        key.contains('secret') ||
        key.contains('authorization') ||
        key == 'password' ||
        key == 'userhash' ||
        key == 'email' ||
        key == 'userid' ||
        key == 'appuserid' ||
        key == 'sdkuserid' ||
        key == 'externaluserid' ||
        key == 'appid' ||
        key == 'deviceid' ||
        key == 'relaydeviceid' ||
        key == 'hardwareid' ||
        key == 'relayhardwareid' ||
        key == 'nodeid' ||
        key == 'originatornodeid' ||
        key == 'relaynodeid' ||
        key == 'incidentid' ||
        key == 'cyclekey' ||
        key == 'id';
  }

  static bool _isLocationJsonKey(String key) {
    return key == 'latitude' ||
        key == 'longitude' ||
        key == 'lat' ||
        key == 'lon';
  }
}
