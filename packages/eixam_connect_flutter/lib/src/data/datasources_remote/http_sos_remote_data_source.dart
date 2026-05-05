import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../../device/ble_debug_registry.dart';
import '../../sdk/sos_backend_identity_normalizer.dart';
import '../dtos/sos_history_dto.dart';
import '../dtos/sos_incident_dto.dart';
import 'sdk_http_transport.dart';
import 'sos_remote_data_source.dart';

/// HTTP implementation of the remote SOS data source.
class HttpSosRemoteDataSource implements SosRemoteDataSource {
  HttpSosRemoteDataSource({
    required this.transport,
  });

  final SdkHttpTransport transport;

  @override
  Future<SosIncidentDto> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
    String? deviceId,
    String? appDeviceId,
    String? hardwareId,
    int? originatorNodeId,
    int? relayNodeId,
    String? relayDeviceId,
    String? relayHardwareId,
    String? relaySource,
    String? incidentId,
    String? cycleKey,
    SdkDeviceBatterySnapshot? deviceBattery,
    SdkCoverageSnapshot? deviceCoverage,
    int? mobileBattery,
    SdkCoverageSnapshot? mobileCoverage,
  }) async {
    final allowsMissingPosition = triggerSource == 'remote_lora_relay';
    if (positionSnapshot == null && !allowsMissingPosition) {
      throw const SosException(
        'E_HTTP_SOS_POSITION_REQUIRED',
        'The production SOS HTTP endpoint requires a position snapshot.',
      );
    }
    final identity = normalizeSosBackendIdentity(
      deviceId: deviceId,
      appDeviceId: appDeviceId,
      originatorNodeId: originatorNodeId,
      relayNodeId: relayNodeId,
      relayDeviceId: relayDeviceId,
      incidentId: incidentId,
      cycleKey: cycleKey,
      hardwareId: hardwareId,
    );
    if (identity.hardwareId != null) {
      BleDebugRegistry.instance.recordEvent(
        'BACKEND_DEVICE_ID_NORMALIZED previousDeviceId=$deviceId '
        'normalizedDeviceId=${identity.deviceId} source=sos',
      );
    }
    if (isBleMacDeviceId(identity.deviceId)) {
      BleDebugRegistry.instance.recordEvent(
        'BACKEND_DEVICE_ID_INVALID invalidBackendDeviceId=${identity.deviceId} source=sos',
      );
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_BACKEND_PAYLOAD_FINAL source=http '
      'owner=${identity.originatorNodeId == null ? "app" : "device"} '
      'triggerSource=$triggerSource '
      'deviceId=${identity.deviceId ?? "none"} '
      'nodeId=${identity.nodeId?.toString() ?? "none"} '
      'appDeviceId=${identity.appDeviceId ?? "none"} '
      'originatorNodeId=${identity.originatorNodeId?.toString() ?? "none"} '
      'relayNodeId=${relayNodeId?.toString() ?? "none"} '
      'relayDeviceId=${identity.relayDeviceId ?? "none"} '
      'hardwareId=${identity.hardwareId ?? "none"} '
      'relayHardwareId=${relayHardwareId ?? "none"} '
      'identitySource=${identity.identitySource} '
      'incidentId=${incidentId ?? "none"} '
      'cycleKey=${cycleKey ?? "none"}',
    );

    final body = jsonEncode({
      'timestamp': (positionSnapshot?.timestamp ?? DateTime.now().toUtc())
          .toIso8601String(),
      if (positionSnapshot != null) ...{
        'latitude': positionSnapshot.latitude,
        'longitude': positionSnapshot.longitude,
        'altitude': positionSnapshot.altitude,
      },
      if (identity.deviceId != null && identity.deviceId!.isNotEmpty)
        'deviceId': identity.deviceId,
      if (identity.originatorNodeId != null) ...{
        'nodeId': identity.originatorNodeId,
        'originatorNodeId': identity.originatorNodeId,
      },
      if (identity.appDeviceId != null && identity.appDeviceId!.isNotEmpty)
        'appDeviceId': identity.appDeviceId,
      if (identity.hardwareId != null && identity.hardwareId!.isNotEmpty)
        'hardwareId': identity.hardwareId,
      'identitySource': identity.identitySource,
      if (relayNodeId != null) 'relayNodeId': relayNodeId,
      if (identity.relayDeviceId != null &&
          identity.relayDeviceId!.isNotEmpty)
        'relayDeviceId': identity.relayDeviceId,
      if (relayHardwareId != null && relayHardwareId.trim().isNotEmpty)
        'relayHardwareId': relayHardwareId.trim(),
      if (relaySource != null && relaySource.trim().isNotEmpty)
        'source': relaySource.trim(),
      if (deviceBattery != null) 'deviceBattery': deviceBattery.toJson(),
      if (deviceCoverage != null) 'deviceCoverage': deviceCoverage.toJson(),
      if (mobileBattery != null) 'mobileBattery': mobileBattery.clamp(0, 100),
      if (mobileCoverage != null) 'mobileCoverage': mobileCoverage.toJson(),
    });
    final correlationId = _nextCorrelationId('sos-http');
    BleDebugRegistry.instance.recordEvent(
      '[SOS_BACKEND_OUTBOUND_FINAL] transport=http '
      'endpoint=/v1/sdk/sos correlationId=$correlationId '
      'source=${relaySource?.trim().isNotEmpty == true ? relaySource!.trim() : triggerSource} '
      'owner=${identity.originatorNodeId == null ? "app" : "device"} '
      'deviceId=${identity.deviceId ?? "none"} '
      'nodeId=${identity.nodeId?.toString() ?? "none"} '
      'originatorNodeId=${identity.originatorNodeId?.toString() ?? "none"} '
      'appDeviceId=${identity.appDeviceId ?? "none"} '
      'hardwareId=${identity.hardwareId ?? "none"} '
      'identitySource=${identity.identitySource} '
      'incidentId=${incidentId ?? "none"} '
      'canonicalIncidentId=none '
      'payload=${_redactedCompactJson(body)}',
    );

    final response = await transport.post(
      '/v1/sdk/sos',
      body: body,
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      BleDebugRegistry.instance.recordEvent(
        '[SOS_BACKEND_RESPONSE] correlationId=$correlationId '
        'status=${response.statusCode} backendIncidentId=none '
        'responseSummary=${_redactedCompactJson(response.body)}',
      );
      throw SosHttpException(
        response.statusCode == 422
            ? 'E_HTTP_SOS_TRIGGER_422'
            : 'E_HTTP_SOS_TRIGGER_FAILED',
        response.body,
        statusCode: response.statusCode,
      );
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final incident = payload['incident'];
    if (incident is! Map<String, dynamic>) {
      BleDebugRegistry.instance.recordEvent(
        '[SOS_BACKEND_RESPONSE] correlationId=$correlationId '
        'status=${response.statusCode} backendIncidentId=none '
        'responseSummary=${_redactedCompactJson(response.body)}',
      );
      throw const SosException(
        'E_HTTP_SOS_TRIGGER_FAILED',
        'The backend did not return an incident payload.',
      );
    }

    final dto = SosIncidentDto.fromJson(incident).copyWith(
      statusCode: response.statusCode,
    );
    BleDebugRegistry.instance.recordEvent(
      '[SOS_BACKEND_RESPONSE] correlationId=$correlationId '
      'status=${response.statusCode} backendIncidentId=${dto.id} '
      'responseSummary=${_redactedCompactJson(response.body)}',
    );
    return dto;
  }

  @override
  Future<SosIncidentDto?> cancelSos({String? deviceId}) async {
    final normalizedDeviceId = deviceId?.trim();
    final body = normalizedDeviceId == null || normalizedDeviceId.isEmpty
        ? null
        : jsonEncode({'deviceId': normalizedDeviceId});
    _logRequest(
      action: 'cancel',
      path: '/v1/sdk/sos/cancel',
      body: body,
    );
    final response = await transport.post(
      '/v1/sdk/sos/cancel',
      body: body,
    );
    _logResponse(
        action: 'cancel', statusCode: response.statusCode, body: response.body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      _logError(
        action: 'cancel',
        code: _cancelErrorCodeForStatus(response.statusCode),
        message: response.body,
      );
      throw SosHttpException(
        _cancelErrorCodeForStatus(response.statusCode),
        response.body,
        statusCode: response.statusCode,
      );
    }

    if (response.body.trim().isEmpty) {
      _logParsed(action: 'cancel', result: 'incident=null');
      return null;
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final incident = payload['incident'];
    if (incident == null) {
      _logParsed(action: 'cancel', result: 'incident=null');
      return null;
    }
    if (incident is! Map<String, dynamic>) {
      _logError(
        action: 'cancel',
        code: 'E_HTTP_SOS_CANCEL_FAILED',
        message: 'The backend returned an invalid incident payload.',
      );
      throw const SosException(
        'E_HTTP_SOS_CANCEL_FAILED',
        'The backend returned an invalid incident payload.',
      );
    }
    final dto = SosIncidentDto.fromJson(incident);
    _logParsed(
        action: 'cancel', result: 'incidentId=${dto.id} state=${dto.state}');
    return dto;
  }

  String _cancelErrorCodeForStatus(int statusCode) {
    return switch (statusCode) {
      400 => 'E_HTTP_SOS_CANCEL_INVALID_REQUEST',
      401 => 'E_HTTP_SOS_CANCEL_UNAUTHORIZED',
      409 => 'E_HTTP_SOS_CANCEL_CONFLICT',
      422 => 'E_HTTP_SOS_CANCEL_UNKNOWN_DEVICE',
      _ => 'E_HTTP_SOS_CANCEL_FAILED',
    };
  }

  @override
  Future<SosIncidentDto?> resolveSos() async {
    _logRequest(
      action: 'resolve',
      path: '/v1/sdk/sos/resolve',
      body: null,
    );
    final response = await transport.post(
      '/v1/sdk/sos/resolve',
    );
    _logResponse(
        action: 'resolve',
        statusCode: response.statusCode,
        body: response.body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      _logError(
        action: 'resolve',
        code: 'E_HTTP_SOS_RESOLVE_FAILED',
        message: response.body,
      );
      throw SosException('E_HTTP_SOS_RESOLVE_FAILED', response.body);
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final incident = payload['incident'];
    if (incident == null) {
      _logParsed(action: 'resolve', result: 'incident=null');
      return null;
    }
    if (incident is! Map<String, dynamic>) {
      _logError(
        action: 'resolve',
        code: 'E_HTTP_SOS_RESOLVE_FAILED',
        message: 'The backend returned an invalid incident payload.',
      );
      throw const SosException(
        'E_HTTP_SOS_RESOLVE_FAILED',
        'The backend returned an invalid incident payload.',
      );
    }
    final dto = SosIncidentDto.fromJson(incident);
    _logParsed(
        action: 'resolve', result: 'incidentId=${dto.id} state=${dto.state}');
    return dto;
  }

  @override
  Future<SosIncidentDto?> getActiveSos() async {
    final response = await transport.get('/v1/sdk/sos');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SosException('E_HTTP_SOS_GET_ACTIVE_FAILED', response.body);
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final incident = payload['incident'];
    if (incident == null) {
      return null;
    }
    if (incident is! Map<String, dynamic>) {
      throw const SosException(
        'E_HTTP_SOS_GET_ACTIVE_FAILED',
        'The backend returned an invalid incident payload.',
      );
    }
    return SosIncidentDto.fromJson(incident);
  }

  @override
  Future<SosHistoryPageDto> listSosHistory(
      {String? cursor, int limit = 20}) async {
    final params = <String, String>{'limit': '$limit'};
    if (cursor != null && cursor.isNotEmpty) {
      params['cursor'] = cursor;
    }
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    final response = await transport.get('/v1/sdk/sos/history?$query');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SosException('E_HTTP_SOS_LIST_HISTORY_FAILED', response.body);
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    return SosHistoryPageDto.fromJson(payload);
  }

  void _logRequest({
    required String action,
    required String path,
    required String? body,
  }) {
    final headers = transport.headersForCurrentSession();
    BleDebugRegistry.instance.recordEvent(
      'SOS HTTP $action request -> method=POST url=${transport.config.apiBaseUrl}$path body=${body ?? '<empty>'}',
    );
    BleDebugRegistry.instance.recordEvent(
      'SOS HTTP $action headers -> X-App-ID=${headers['X-App-ID']} X-User-ID=${headers['X-User-ID']} Authorization=Bearer <redacted> Content-Type=${headers['Content-Type']}',
    );
  }

  void _logResponse({
    required String action,
    required int statusCode,
    required String body,
  }) {
    BleDebugRegistry.instance.recordEvent(
      'SOS HTTP $action response -> status=$statusCode body=$body',
    );
  }

  void _logParsed({
    required String action,
    required String result,
  }) {
    BleDebugRegistry.instance.recordEvent(
      'SOS HTTP $action parsed -> $result',
    );
  }

  void _logError({
    required String action,
    required String code,
    required String message,
  }) {
    BleDebugRegistry.instance.recordEvent(
      'SOS HTTP $action error -> code=$code message=$message',
    );
  }

  String _nextCorrelationId(String prefix) =>
      '$prefix-${DateTime.now().toUtc().microsecondsSinceEpoch}';

  String _redactedCompactJson(String payload) {
    try {
      return jsonEncode(_redactJsonValue(jsonDecode(payload)));
    } catch (_) {
      return _compactSummary(payload);
    }
  }

  Object? _redactJsonValue(Object? value, {String? key}) {
    final normalizedKey = key?.toLowerCase();
    if (normalizedKey != null &&
        (normalizedKey.contains('token') ||
            normalizedKey.contains('secret') ||
            normalizedKey.contains('authorization') ||
            normalizedKey == 'password' ||
            normalizedKey == 'userhash' ||
            normalizedKey == 'email')) {
      return '<redacted>';
    }
    if (normalizedKey == 'userid' && value is String && value.contains('@')) {
      return '<redacted-email>';
    }
    if (value is Map) {
      return value.map<String, Object?>(
        (key, child) => MapEntry(
          key.toString(),
          _redactJsonValue(child, key: key.toString()),
        ),
      );
    }
    if (value is List) {
      return value.map((child) => _redactJsonValue(child)).toList();
    }
    return value;
  }

  String _compactSummary(Object? value) {
    final summary = value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (summary.isEmpty) {
      return 'none';
    }
    return summary.length <= 240 ? summary : '${summary.substring(0, 240)}...';
  }
}
