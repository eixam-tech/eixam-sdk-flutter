import '../entities/sos_incident.dart';
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
  });

  Future<SosIncident> cancelSos();
  Future<SosState> getSosState();
  Stream<SosState> watchSosState();
}
