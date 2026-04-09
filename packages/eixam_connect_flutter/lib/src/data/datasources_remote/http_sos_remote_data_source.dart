import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';

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
    final response = await transport.post(
      '/v1/sdk/sos/cancel',
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SosException('E_HTTP_SOS_CANCEL_FAILED', response.body);
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final incident = payload['incident'];
    if (incident == null) {
      return null;
    }
    if (incident is! Map<String, dynamic>) {
      throw const SosException(
        'E_HTTP_SOS_CANCEL_FAILED',
        'The backend returned an invalid incident payload.',
      );
    }
    return SosIncidentDto.fromJson(incident);
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
}
