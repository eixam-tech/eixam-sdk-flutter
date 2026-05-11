import '../entities/sos_history_item.dart';
import '../entities/sos_incident.dart';
import '../entities/sdk_telemetry_payload.dart';
import '../entities/tracking_position.dart';
import '../enums/sos_state.dart';

/// Contract for SOS data operations.
///
/// Implementations may talk to an in-memory store, a remote API, or both. The
/// interface supports a best-effort [positionSnapshot] so the SDK can attach the
/// latest known user location to an emergency trigger without blocking the SOS.
abstract class SosRepository {
  Future<SosIncident> triggerSos({
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

  Future<SosIncident> cancelSos();
  Future<SosIncident> resolveSos();
  Future<SosIncident?> getCurrentIncident();
  Future<SosState> getSosState();
  Stream<SosState> watchSosState();

  /// Returns paginated SOS history for the authenticated user.
  ///
  /// [cursor] is the `nextCursor` from the previous page. [limit] defaults to 20
  /// and is capped at 100 by the backend.
  Future<SosHistoryPage> listSosHistory({String? cursor, int limit = 20});
}
