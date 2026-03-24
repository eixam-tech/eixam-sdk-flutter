import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
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
  });
}
