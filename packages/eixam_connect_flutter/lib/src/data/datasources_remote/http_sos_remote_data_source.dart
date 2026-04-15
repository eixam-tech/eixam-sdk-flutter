import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../../device/ble_debug_registry.dart';
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
  }) async {
    if (positionSnapshot == null) {
      throw const SosException(
        'E_HTTP_SOS_POSITION_REQUIRED',
        'The production SOS HTTP endpoint requires a position snapshot.',
      );
    }

    final response = await transport.post(
      '/v1/sdk/sos',
      body: jsonEncode({
        'timestamp': positionSnapshot.timestamp.toIso8601String(),
        'latitude': positionSnapshot.latitude,
        'longitude': positionSnapshot.longitude,
        'altitude': positionSnapshot.altitude,
        if (deviceId != null && deviceId.trim().isNotEmpty)
          'deviceId': deviceId.trim(),
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SosException('E_HTTP_SOS_TRIGGER_FAILED', response.body);
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final incident = payload['incident'];
    if (incident is! Map<String, dynamic>) {
      throw const SosException(
        'E_HTTP_SOS_TRIGGER_FAILED',
        'The backend did not return an incident payload.',
      );
    }

    return SosIncidentDto.fromJson(incident);
  }

  @override
  Future<SosIncidentDto?> cancelSos() async {
    _logRequest(
      action: 'cancel',
      path: '/v1/sdk/sos/cancel',
      body: null,
    );
    final response = await transport.post(
      '/v1/sdk/sos/cancel',
    );
    _logResponse(action: 'cancel', statusCode: response.statusCode, body: response.body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      _logError(
        action: 'cancel',
        code: 'E_HTTP_SOS_CANCEL_FAILED',
        message: response.body,
      );
      throw SosException('E_HTTP_SOS_CANCEL_FAILED', response.body);
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
    _logParsed(action: 'cancel', result: 'incidentId=${dto.id} state=${dto.state}');
    return dto;
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
    _logResponse(action: 'resolve', statusCode: response.statusCode, body: response.body);

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
    _logParsed(action: 'resolve', result: 'incidentId=${dto.id} state=${dto.state}');
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
}
