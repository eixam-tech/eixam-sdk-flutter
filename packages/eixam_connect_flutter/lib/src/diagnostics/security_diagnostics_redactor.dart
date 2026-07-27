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
    final present = switch (value) {
      null => false,
      String text => text.trim().isNotEmpty,
      _ => true,
    };
    if (!present) {
      return 'none';
    }
    if (allowSensitive) {
      return value is String ? value.trim() : redacted;
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
    var sanitized = message.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b(attemptId|attempt_id)=([^\s]+)',
        caseSensitive: false,
      ),
      (match) => 'attempt_present=${_isPresentToken(match[2])}',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b(timestamp|lastPacketAt|updatedAt|startedAt|deadline|activationDeadline|expectedActivationAt|receivedAt|observedAt|expiresAt|now)=([^\s]+)',
        caseSensitive: false,
      ),
      (match) => 'timestamp_present=${_isPresentToken(match[2])}',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b[A-Za-z][A-Za-z0-9_]*(?:At|Timestamp|Deadline)=\d{4}-\d{2}-\d{2}T[^\s]+',
      ),
      (match) => 'timestamp_present=true',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'\b(?:ageMs|freshnessMs|lastKnownAgeMs|latestTelAgeMs)=(-?\d+)'),
      (match) => 'age_category=${_ageCategory(match[1])}',
    );
    if (allowSensitive) {
      return sanitized;
    }
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b(payloadHex|rawHex|raw|packet|payload)=((?:[0-9a-fA-F]{2}(?:[\s:,-]+(?=[0-9a-fA-F]{2}(?:[\s:,-]|$)))?)+)',
      ),
      (match) => 'packet_bytes_present=true',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'\b(body|responseBody|responseSummary|payload|message)=\{.*\}'),
      (match) => 'payload_present=true',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'\b(payload|body)=\[[^\]]*\]'),
      (match) => 'payload_present=true',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'\b(topic|endpoint)=\S+'),
      (match) => 'topic_category=${_topicCategory(match[0])}',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'\b(uri|brokerUri|server)=\S+'),
      (match) => 'transport_endpoint_present=true',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b([A-Za-z0-9_]*(?:userId|email|phone|token)[A-Za-z0-9_]*)=(.*?)(?=\s+[A-Za-z][A-Za-z0-9_]*=|$)',
        caseSensitive: false,
      ),
      (match) => 'user_identity_present=${_isPresentToken(match[2])}',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b([A-Za-z0-9_]*(?:deviceId|hardwareId|deviceIdentity|hardwareIdentity|deviceMac|hardwareMac)[A-Za-z0-9_]*)=(.*?)(?=\s+[A-Za-z][A-Za-z0-9_]*=|$)',
        caseSensitive: false,
      ),
      (match) => 'device_identity_present=${_isPresentToken(match[2])}',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b([A-Za-z0-9_]*nodeIds?[A-Za-z0-9_]*)=(.*?)(?=\s+[A-Za-z][A-Za-z0-9_]*=|$)',
        caseSensitive: false,
      ),
      (match) =>
          '${(match[1] ?? '').toLowerCase().contains('relay') ? 'relay_identity' : 'originator_identity'}_present=${_isPresentToken(match[2])}',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b([A-Za-z0-9_]*incident[A-Za-z0-9_]*)=(.*?)(?=\s+[A-Za-z][A-Za-z0-9_]*=|$)',
        caseSensitive: false,
      ),
      (match) => 'incident_present=${_isPresentToken(match[2])}',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b(cycle|[A-Za-z0-9_]*Cycle(?:Id|Key)?[A-Za-z0-9_]*)=(.*?)(?=\s+[A-Za-z][A-Za-z0-9_]*=|$)',
      ),
      (match) => 'packet_identity_present=${_isPresentToken(match[2])}',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b([A-Za-z0-9_]*(?:correlationId|signature|dedupeKey)[A-Za-z0-9_]*)=(.*?)(?=\s+[A-Za-z][A-Za-z0-9_]*=|$)',
        caseSensitive: false,
      ),
      (match) =>
          '${(match[1] ?? '').toLowerCase().contains('correlation') ? 'correlation' : 'packet_identity'}_present=${_isPresentToken(match[2])}',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b(flagsWord|statusByte|packetTypeByte|eventOpcode|eventSubcode|lastByte|sequenceByte)=([^\s]+)',
      ),
      (match) => 'packet_metadata_present=true',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b(X-App-ID|appId)=(.*?)(?=\s+[A-Za-z][A-Za-z0-9_-]*=|$)',
      ),
      (match) => 'app_identity_present=${_isPresentToken(match[2])}',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b(X-User-ID|userId|sdkUserId|externalUserId|email|phone|token|accessToken|refreshToken|sessionToken)=(.*?)(?=\s+[A-Za-z][A-Za-z0-9_-]*=|$)',
      ),
      (match) => 'user_identity_present=${_isPresentToken(match[2])}',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b(device|gateway|remote|deviceId|normalizedDeviceId|invalidBackendDeviceId|backendDeviceId|relayDeviceId|hardwareId|relayHardwareId|registeredHardwareId|runtimeDeviceId|backendHardwareId|bleHardwareId|logicalId|boundDeviceId|activeBleHardwareId)=(.*?)(?=\s+[A-Za-z][A-Za-z0-9_]*=|$)',
      ),
      (match) => 'device_identity_present=${_isPresentToken(match[2])}',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b(id|name|displayName|contact|address|label)=(.*?)(?=\s+[A-Za-z][A-Za-z0-9_]*=|$)',
      ),
      (match) => 'identity_detail_present=${_isPresentToken(match[2])}',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b(incidentId|canonicalIncidentId|backendIncidentId|responseIncidentId)=(.*?)(?=\s+[A-Za-z][A-Za-z0-9_]*=|$)',
      ),
      (match) => 'incident_present=${_isPresentToken(match[2])}',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b(correlationId|cycleKey|signature|lastPacketSignature)=(.*?)(?=\s+[A-Za-z][A-Za-z0-9_]*=|$)',
      ),
      (match) =>
          '${match[1] == 'correlationId' ? 'correlation' : 'packet_identity'}_present=${_isPresentToken(match[2])}',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b(nodeId|originatorNodeId|relayNodeId|strictConnectedBleNodeId|connectedBleNodeId|boundNodeId|packetId|lastOpcode|opcode|subcode)=(.*?)(?=\s+[A-Za-z][A-Za-z0-9_]*=|$)',
      ),
      (match) =>
          '${match[1] == 'relayNodeId' ? 'relay_identity' : 'originator_identity'}_present=${_isPresentToken(match[2])}',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b(lat|lon|lng|latitude|longitude|previousLat|previousLon|newLat|newLon)=(-?\d+(?:\.\d+)?)',
      ),
      (match) => 'location_available=true',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(r'\b(position|coordinate|location)=([^\s]+)'),
      (match) => 'location_available=${_isPresentToken(match[2])}',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b(alt|altitude|accuracy|horizontalAccuracy|verticalAccuracy)=(-?\d+(?:\.\d+)?)',
      ),
      (match) =>
          '${match[1] == 'accuracy' || match[1] == 'horizontalAccuracy' ? 'accuracy_available' : 'altitude_available'}=true',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b([A-Za-z0-9_]*(?:error|exception|stack|message)[A-Za-z0-9_]*)=(.*?)(?=\s+[A-Za-z][A-Za-z0-9_]*=|$)',
        caseSensitive: false,
      ),
      (match) => 'error_category=${errorCategory(match[2])}',
    );
    sanitized = sanitized.replaceAllMapped(
      RegExp(
        r'\b(failed|failure|error|exception):\s*(.*)$',
        caseSensitive: false,
      ),
      (match) => '${match[1]} error_category=${errorCategory(match[2])}',
    );
    return sanitized.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String structuredEvent(
    String event, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    final normalizedEvent = _boundedToken(event, fallback: 'diagnostic_event');
    final parts = <String>[normalizedEvent];
    for (final entry in fields.entries) {
      final key = _boundedToken(entry.key, fallback: 'field');
      if (!_releaseAllowedKeys.contains(key)) {
        continue;
      }
      final value = _safeStructuredValue(entry.value);
      parts.add('$key=$value');
    }
    return parts.join(' ');
  }

  static String errorCategory(Object? error) {
    if (error == null) {
      return 'none';
    }
    final type = error is String ? error : error.runtimeType.toString();
    final normalized = type.toLowerCase();
    if (normalized.contains('timeout')) {
      return 'timeout';
    }
    if (normalized.contains('socket') ||
        normalized.contains('network') ||
        normalized.contains('mqtt')) {
      return 'transport';
    }
    if (normalized.contains('auth') || normalized.contains('permission')) {
      return 'authorization';
    }
    if (normalized.contains('format') ||
        normalized.contains('parse') ||
        normalized.contains('json')) {
      return 'invalid_data';
    }
    if (normalized.contains('state')) {
      return 'invalid_state';
    }
    return 'unexpected';
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
    if (value == null) {
      return 'none';
    }
    if (value is! String && value is! num && value is! bool) {
      return 'error_category=${errorCategory(value)}';
    }
    final summary = value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (summary.isEmpty) {
      return 'none';
    }
    final bounded = summary.length <= maxLength
        ? summary
        : '${summary.substring(0, maxLength)}...';
    return sanitizeEventMessage(bounded, allowSensitive: false);
  }

  static const Set<String> _releaseAllowedKeys = <String>{
    'event',
    'action',
    'stage',
    'source',
    'origin',
    'transport',
    'result',
    'reason',
    'state',
    'previous_state',
    'next_state',
    'topic_category',
    'error_category',
    'location_available',
    'device_identity_present',
    'originator_identity_present',
    'relay_identity_present',
    'incident_present',
    'packet_identity_present',
    'correlation_present',
    'payload_present',
    'canonical_handoff',
    'retry',
    'count',
    'revision',
    'elapsed_ms',
    'available',
    'ready',
    'connected',
    'authorized',
  };

  static String _safeStructuredValue(Object? value) {
    return switch (value) {
      null => 'none',
      bool boolean => boolean.toString(),
      int integer => integer.toString(),
      double number when number.isFinite => number.toString(),
      String text => _boundedToken(text, fallback: 'unknown'),
      _ => 'present',
    };
  }

  static String _boundedToken(String value, {required String fallback}) {
    final normalized = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_.-]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (normalized.isEmpty) {
      return fallback;
    }
    return normalized.length <= 64 ? normalized : normalized.substring(0, 64);
  }

  static String _isPresentToken(String? value) {
    final normalized = value?.trim().toLowerCase();
    return normalized == null ||
            normalized.isEmpty ||
            normalized == 'none' ||
            normalized == 'null' ||
            normalized == 'false'
        ? 'false'
        : 'true';
  }

  static String _ageCategory(String? value) {
    final ageMs = int.tryParse(value ?? '');
    if (ageMs == null) {
      return 'unknown';
    }
    if (ageMs < 0) {
      return 'future';
    }
    if (ageMs <= const Duration(seconds: 30).inMilliseconds) {
      return 'fresh';
    }
    if (ageMs <= const Duration(minutes: 10).inMilliseconds) {
      return 'recent';
    }
    return 'stale';
  }

  static String _topicCategory(String? value) {
    final normalized = value?.toLowerCase() ?? '';
    if (normalized.contains('legacy')) {
      return 'legacy_alias';
    }
    if (normalized.contains('sos') || normalized.contains('telemetry')) {
      return 'operational';
    }
    return 'internal';
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
