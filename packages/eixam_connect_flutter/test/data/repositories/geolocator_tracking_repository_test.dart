import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/data/repositories/geolocator_tracking_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../../support/fakes/sdk_contract_fakes.dart';

void main() {
  group('GeolocatorTrackingRepository.restoreState', () {
    test('restores persisted position and explicit tracking state', () async {
      final store = MemorySharedPrefsSdkStore()
        ..jsonValues[SharedPrefsSdkStore.trackingPositionKey] = <String, dynamic>{
          'latitude': 41.3874,
          'longitude': 2.1686,
          'source': DeliveryMode.mobile.name,
          'timestamp': DateTime.utc(2026, 1, 1, 12).toIso8601String(),
        }
        ..stringValues[SharedPrefsSdkStore.trackingStateKey] =
            TrackingState.tracking.name;

      final repository = GeolocatorTrackingRepository(
        permissionsRepository: FakePermissionsRepository(),
        localStore: store,
      );
      final positionFuture = repository.watchPositions().first;

      await repository.restoreState();

      final position = await positionFuture;
      expect(position.latitude, 41.3874);
      expect(await repository.getTrackingState(), TrackingState.tracking);
    });

    test('falls back to stale when restored position is old and no state is persisted', () async {
      final store = MemorySharedPrefsSdkStore()
        ..jsonValues[SharedPrefsSdkStore.trackingPositionKey] = <String, dynamic>{
          'latitude': 41.3874,
          'longitude': 2.1686,
          'source': DeliveryMode.mobile.name,
          'timestamp': DateTime.now()
              .subtract(const Duration(minutes: 3))
              .toIso8601String(),
        };

      final repository = GeolocatorTrackingRepository(
        permissionsRepository: FakePermissionsRepository(),
        localStore: store,
      );

      await repository.restoreState();

      expect(await repository.getTrackingState(), TrackingState.stale);
    });
  });
}
