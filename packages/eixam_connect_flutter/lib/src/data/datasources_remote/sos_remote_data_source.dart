import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../dtos/sos_incident_dto.dart';

/// Defines the remote contract for SOS operations.
abstract class SosRemoteDataSource {
  Future<SosIncidentDto> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
  });

  Future<SosIncidentDto> cancelSos({required String incidentId, String? reason});
  Future<SosIncidentDto?> getActiveSos();
}
