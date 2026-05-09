import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../dtos/sos_history_dto.dart';
import '../dtos/sos_incident_dto.dart';

/// Defines the remote contract for SOS operations.
abstract class SosRemoteDataSource {
  Future<SosIncidentDto> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
    String? deviceId,
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
  });

  Future<SosIncidentDto?> cancelSos({String? deviceId});
  Future<SosIncidentDto?> resolveSos();
  Future<SosIncidentDto?> getActiveSos();
  Future<SosHistoryPageDto> listSosHistory({String? cursor, int limit = 20});
}
