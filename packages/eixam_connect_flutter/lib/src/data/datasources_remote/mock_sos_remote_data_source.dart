import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../dtos/sos_incident_dto.dart';
import 'sos_remote_data_source.dart';

/// Mock remote data source useful while the real backend is not available.
class MockSosRemoteDataSource implements SosRemoteDataSource {
  SosIncidentDto? _active;

  @override
  Future<SosIncidentDto> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _active = SosIncidentDto(
      id: 'api-sos-${DateTime.now().millisecondsSinceEpoch}',
      state: SosState.sent.name,
      createdAt: DateTime.now().toIso8601String(),
      triggerSource: triggerSource,
      message: message,
      positionSnapshot: positionSnapshot == null
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
    );
    return _active!;
  }

  @override
  Future<SosIncidentDto> cancelSos({required String incidentId, String? reason}) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (_active == null || _active!.id != incidentId) {
      throw const SosException('E_SOS_NOT_FOUND', 'Active SOS incident not found');
    }
    _active = _active!.copyWith(state: SosState.cancelled.name);
    return _active!;
  }

  @override
  Future<SosIncidentDto?> getActiveSos() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return _active;
  }
}
