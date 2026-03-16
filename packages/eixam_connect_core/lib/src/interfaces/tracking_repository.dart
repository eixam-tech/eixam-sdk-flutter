import '../entities/tracking_position.dart';
import '../enums/tracking_state.dart';

abstract class TrackingRepository {
  Future<void> startTracking();
  Future<void> stopTracking();
  Future<TrackingPosition?> getCurrentPosition();
  Future<TrackingState> getTrackingState();
  Stream<TrackingPosition> watchPositions();
  Stream<TrackingState> watchTrackingState();
}
