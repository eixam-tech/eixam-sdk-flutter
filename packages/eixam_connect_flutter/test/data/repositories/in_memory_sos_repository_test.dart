import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes/memory_shared_prefs_sdk_store.dart';

void main() {
  group('InMemorySosRepository', () {
    test('emits the expected happy-path states when triggering SOS', () async {
      final repository = InMemorySosRepository();
      final emitted = <SosState>[];
      final subscription = repository.watchSosState().listen(emitted.add);

      final incident = await repository.triggerSos(
        message: 'Help',
        triggerSource: 'button_ui',
      );

      await Future<void>.delayed(Duration.zero);

      expect(incident.state, SosState.sent);
      expect(await repository.getSosState(), SosState.sent);
      expect(
        emitted,
        containsAllInOrder(<SosState>[
          SosState.triggerRequested,
          SosState.triggeredLocal,
          SosState.sending,
          SosState.sent,
        ]),
      );

      await subscription.cancel();
    });

    test('rejects triggering a second SOS while one is active', () async {
      final repository = InMemorySosRepository();

      await repository.triggerSos(triggerSource: 'button_ui');

      await expectLater(
        repository.triggerSos(triggerSource: 'button_ui'),
        throwsA(
          isA<SosException>().having(
            (error) => error.code,
            'code',
            'E_SOS_ALREADY_ACTIVE',
          ),
        ),
      );
    });

    test('cancels an active SOS and updates the state', () async {
      final repository = InMemorySosRepository();

      await repository.triggerSos(triggerSource: 'button_ui');
      final cancelled = await repository.cancelSos(reason: 'False alarm');

      expect(cancelled.state, SosState.cancelled);
      expect(await repository.getSosState(), SosState.cancelled);
    });

    test('restores persisted SOS incident and state', () async {
      final store = MemorySharedPrefsSdkStore()
        ..stringValues[SharedPrefsSdkStore.sosStateKey] = SosState.sent.name
        ..jsonValues[SharedPrefsSdkStore.sosIncidentKey] = <String, dynamic>{
          'id': 'sos-42',
          'state': SosState.sent.name,
          'createdAt': DateTime.utc(2026, 1, 1, 12).toIso8601String(),
          'triggerSource': 'button_ui',
          'message': 'Need help',
          'positionSnapshot': <String, dynamic>{
            'latitude': 41.3874,
            'longitude': 2.1686,
            'source': DeliveryMode.mobile.name,
            'timestamp': DateTime.utc(2026, 1, 1, 12).toIso8601String(),
          },
        };
      final repository = InMemorySosRepository(localStore: store);

      await repository.restoreState();

      expect(await repository.getSosState(), SosState.sent);
    });

    test('persists cancellation state and keeps the active incident snapshot',
        () async {
      final store = MemorySharedPrefsSdkStore();
      final repository = InMemorySosRepository(localStore: store);

      await repository.triggerSos(
        message: 'Need help',
        triggerSource: 'button_ui',
      );
      await repository.cancelSos(reason: 'Resolved');

      expect(store.stringValues[SharedPrefsSdkStore.sosStateKey],
          SosState.cancelled.name);
      expect(store.jsonValues[SharedPrefsSdkStore.sosIncidentKey], isNotNull);
      expect(
        store.jsonValues[SharedPrefsSdkStore.sosIncidentKey]?['state'],
        SosState.cancelled.name,
      );
    });

    test('rejects cancellation when no active SOS exists', () async {
      final repository = InMemorySosRepository();

      await expectLater(
        repository.cancelSos(reason: 'Nothing to cancel'),
        throwsA(
          isA<SosException>().having(
            (error) => error.code,
            'code',
            'E_SOS_CANCEL_NOT_ALLOWED',
          ),
        ),
      );
    });
  });
}
