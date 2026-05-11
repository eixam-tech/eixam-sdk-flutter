import 'package:eixam_connect_core/eixam_connect_core.dart';

class SosBackendIdentity {
  const SosBackendIdentity({
    required this.deviceId,
    required this.nodeId,
    required this.originatorNodeId,
    required this.relayDeviceId,
    required this.hardwareId,
    required this.identitySource,
  });

  final String? deviceId;
  final int? nodeId;
  final int? originatorNodeId;
  final String? relayDeviceId;
  final String? hardwareId;
  final String identitySource;
}

class TelemetryBackendIdentity {
  const TelemetryBackendIdentity({
    required this.payload,
    required this.nodeId,
    required this.hardwareId,
    required this.identitySource,
    required this.previousDeviceId,
    required this.normalized,
    required this.invalidDeviceId,
  });

  final SdkTelemetryPayload payload;
  final int? nodeId;
  final String? hardwareId;
  final String identitySource;
  final String? previousDeviceId;
  final bool normalized;
  final bool invalidDeviceId;
}

SosBackendIdentity normalizeSosBackendIdentity({
  required String? deviceId,
  required int? originatorNodeId,
  required int? relayNodeId,
  required String? relayDeviceId,
  String? incidentId,
  String? cycleKey,
  String? hardwareId,
}) {
  final parsedNodeId = originatorNodeId ??
      _parseDeviceRuntimeIncidentNodeId(incidentId) ??
      _parseSosCycleNodeId(cycleKey);
  final trimmedDeviceId = deviceId?.trim();
  final normalizedHardwareId = _firstText(<String?>[
    hardwareId,
    parsedNodeId != null &&
            _hasText(trimmedDeviceId) &&
            !_isNodeIdString(trimmedDeviceId, parsedNodeId)
        ? trimmedDeviceId
        : null,
    _looksLikeBleMac(trimmedDeviceId) ? trimmedDeviceId : null,
  ]);
  final normalizedDeviceId = parsedNodeId?.toString() ??
      (_looksLikeBleMac(trimmedDeviceId)
          ? null
          : _emptyToNull(trimmedDeviceId));
  final identitySource = parsedNodeId != null
      ? 'ble_node'
      : normalizedHardwareId != null
          ? 'device_hardware_pending'
          : 'app';
  final normalizedRelayDeviceId =
      relayNodeId?.toString() ?? relayDeviceId?.trim();

  return SosBackendIdentity(
    deviceId: normalizedDeviceId,
    nodeId: parsedNodeId,
    originatorNodeId: parsedNodeId,
    relayDeviceId:
        normalizedRelayDeviceId == null || normalizedRelayDeviceId.isEmpty
            ? null
            : normalizedRelayDeviceId,
    hardwareId: normalizedHardwareId,
    identitySource: identitySource,
  );
}

TelemetryBackendIdentity normalizeTelemetryBackendIdentity({
  required SdkTelemetryPayload payload,
  String? hardwareId,
}) {
  final nodeId = payload.nodeId;
  final previousDeviceId = payload.deviceId?.trim();
  final normalizedHardwareId = _firstText(<String?>[
    payload.hardwareId,
    hardwareId,
    _looksLikeBleMac(previousDeviceId) ? previousDeviceId : null,
  ]);
  if (nodeId != null) {
    final normalizedDeviceId = nodeId.toString();
    return TelemetryBackendIdentity(
      payload: payload.copyWith(
        deviceId: normalizedDeviceId,
        hardwareId: normalizedHardwareId,
        identitySource: 'ble_node',
      ),
      nodeId: nodeId,
      hardwareId: normalizedHardwareId,
      identitySource: 'ble_node',
      previousDeviceId: previousDeviceId,
      normalized: previousDeviceId != null &&
          previousDeviceId.isNotEmpty &&
          previousDeviceId != normalizedDeviceId,
      invalidDeviceId: false,
    );
  }

  final invalid = _looksLikeBleMac(previousDeviceId);
  final normalizedDeviceId = invalid ? null : _emptyToNull(previousDeviceId);
  final identitySource =
      normalizedHardwareId != null ? 'device_hardware' : 'app';
  return TelemetryBackendIdentity(
    payload: payload.copyWith(
      deviceId: normalizedDeviceId,
      hardwareId: normalizedHardwareId,
      identitySource: identitySource,
    ),
    nodeId: null,
    hardwareId: normalizedHardwareId,
    identitySource: identitySource,
    previousDeviceId: previousDeviceId,
    normalized: previousDeviceId != null &&
        previousDeviceId.isNotEmpty &&
        previousDeviceId != normalizedDeviceId,
    invalidDeviceId: _looksLikeBleMac(normalizedDeviceId),
  );
}

bool isBleMacDeviceId(String? value) => _looksLikeBleMac(value);

int? _parseDeviceRuntimeIncidentNodeId(String? incidentId) {
  const prefix = 'device-runtime-sos:';
  if (incidentId == null || !incidentId.startsWith(prefix)) {
    return null;
  }
  return _parseFirstIntSegment(incidentId.substring(prefix.length));
}

int? _parseSosCycleNodeId(String? cycleKey) {
  if (cycleKey == null) {
    return null;
  }
  const dedupePrefix = 'sos-cycle:sos:';
  if (cycleKey.startsWith(dedupePrefix)) {
    return _parseFirstIntSegment(cycleKey.substring(dedupePrefix.length));
  }
  const cyclePrefix = 'sos:';
  if (cycleKey.startsWith(cyclePrefix)) {
    return _parseFirstIntSegment(cycleKey.substring(cyclePrefix.length));
  }
  return null;
}

int? _parseFirstIntSegment(String value) {
  final segment = value.split(':').first.trim();
  if (segment.isEmpty) {
    return null;
  }
  return int.tryParse(segment);
}

String? _firstText(Iterable<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return null;
}

String? _emptyToNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

bool _hasText(String? value) => value != null && value.trim().isNotEmpty;

bool _isNodeIdString(String? value, int nodeId) => value?.trim() == '$nodeId';

bool _looksLikeBleMac(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null) {
    return false;
  }
  return RegExp(r'^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$').hasMatch(trimmed);
}
