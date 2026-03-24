import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  group('DeathManStateMachine', () {
    test('allows the monitoring to expiration flow', () {
      final machine = DeathManStateMachine();

      expect(machine.transitionTo(DeathManStatus.monitoring),
          DeathManStatus.monitoring);
      expect(
          machine.transitionTo(DeathManStatus.overdue), DeathManStatus.overdue);
      expect(
        machine.transitionTo(DeathManStatus.awaitingConfirmation),
        DeathManStatus.awaitingConfirmation,
      );
      expect(
          machine.transitionTo(DeathManStatus.expired), DeathManStatus.expired);
    });

    test('allows cancellation before expiration', () {
      final machine = DeathManStateMachine();

      machine.transitionTo(DeathManStatus.monitoring);

      expect(machine.transitionTo(DeathManStatus.cancelled),
          DeathManStatus.cancelled);
    });

    test('rejects invalid transitions', () {
      final machine = DeathManStateMachine();

      expect(
        () => machine.transitionTo(DeathManStatus.expired),
        throwsA(
          isA<DeathManException>().having(
            (error) => error.code,
            'code',
            'E_DEATH_MAN_INVALID_TRANSITION',
          ),
        ),
      );
      expect(machine.current, DeathManStatus.scheduled);
    });
  });
}
