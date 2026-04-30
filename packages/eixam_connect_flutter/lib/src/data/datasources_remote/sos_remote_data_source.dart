import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../dtos/sos_incident_dto.dart';

/// Defines the remote contract for SOS operations.
abstract class SosRemoteDataSource {
  Future<SosIncidentDto> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
    String? deviceId,
    int? originatorNodeId,
    int? relayNodeId,
    String? relayDeviceId,
    String? relayHardwareId,
    String? relaySource,
    SdkDeviceBatterySnapshot? deviceBattery,
    SdkCoverageSnapshot? deviceCoverage,
    int? mobileBattery,
    SdkCoverageSnapshot? mobileCoverage,
  });

  Future<SosIncidentDto?> cancelSos({String? deviceId});
  Future<SosIncidentDto?> resolveSos();
  Future<SosIncidentDto?> getActiveSos();
}
