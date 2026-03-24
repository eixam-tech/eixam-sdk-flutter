import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

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
          SosState.idle,
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
  });
}
