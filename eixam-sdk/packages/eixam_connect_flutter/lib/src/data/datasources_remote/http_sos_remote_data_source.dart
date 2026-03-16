import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:http/http.dart' as http;

import '../dtos/sos_incident_dto.dart';
import 'sos_remote_data_source.dart';

/// HTTP implementation of the remote SOS data source.
class HttpSosRemoteDataSource implements SosRemoteDataSource {
  HttpSosRemoteDataSource({
    required this.client,
    required this.config,
    this.authToken,
  });

  final http.Client client;
  final EixamSdkConfig config;
  final String? authToken;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (authToken != null && authToken!.isNotEmpty) 'Authorization': 'Bearer $authToken',
      };

  @override
  Future<SosIncidentDto> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
  }) async {
    final uri = Uri.parse('${config.apiBaseUrl}/alerts/sos');
    final response = await client.post(
      uri,
      headers: _headers,
      body: jsonEncode({
        'message': message,
        'trigger_source': triggerSource,
        'position_snapshot': positionSnapshot == null
            ? null
            : {
                'latitude': positionSnapshot.latitude,
                'longitude': positionSnapshot.longitude,
                'altitude': positionSnapshot.altitude,
                'accuracy': positionSnapshot.accuracy,
                'speed': positionSnapshot.speed,
                'heading': positionSnapshot.heading,
                'source': positionSnapshot.source.name,
                'timestamp': positionSnapshot.timestamp.toIso8601String(),
              },
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SosException('E_HTTP_SOS_TRIGGER_FAILED', response.body);
    }

    return SosIncidentDto.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  @override
  Future<SosIncidentDto> cancelSos({required String incidentId, String? reason}) async {
    final uri = Uri.parse('${config.apiBaseUrl}/alerts/sos/$incidentId/cancel');
    final response = await client.post(
      uri,
      headers: _headers,
      body: jsonEncode({'reason': reason}),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SosException('E_HTTP_SOS_CANCEL_FAILED', response.body);
    }

    return SosIncidentDto.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  @override
  Future<SosIncidentDto?> getActiveSos() async {
    final uri = Uri.parse('${config.apiBaseUrl}/alerts/sos/active');
    final response = await client.get(uri, headers: _headers);

    if (response.statusCode == 404 || response.body.isEmpty) {
      return null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SosException('E_HTTP_SOS_GET_ACTIVE_FAILED', response.body);
    }

    return SosIncidentDto.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }
}
