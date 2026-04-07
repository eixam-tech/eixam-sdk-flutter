import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/repositories/in_memory_tracking_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InMemoryTrackingRepository', () {
    test('starts and stops tracking while updating the public tracking state',
        () async {
      final repository = InMemoryTrackingRepository();

      expect(await repository.getTrackingState(), TrackingState.idle);

      await repository.startTracking();
      expect(await repository.getTrackingState(), TrackingState.tracking);

      await repository.stopTracking();
      expect(await repository.getTrackingState(), TrackingState.idle);
    });

    test('watchTrackingState yields the current state for each new subscriber',
        () async {
      final repository = InMemoryTrackingRepository();

      expect(await repository.watchTrackingState().first, TrackingState.idle);

      await repository.startTracking();
      expect(
          await repository.watchTrackingState().first, TrackingState.tracking);
    });

    test('watchPositions replays the current last known position', () async {
      final repository = InMemoryTrackingRepository(
        initialPosition: TrackingPosition(
          latitude: 41.38,
          longitude: 2.17,
          timestamp: DateTime.utc(2026, 1, 1, 10),
          source: DeliveryMode.mobile,
        ),
        initialState: TrackingState.tracking,
      );

      final position = await repository.watchPositions().first;

      expect(position.latitude, 41.38);
      expect(position.longitude, 2.17);
    });
  });
}
