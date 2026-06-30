import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  group('DeathManStateMachine', () {
    test('allows scheduled to monitoring', () {
      final machine = DeathManStateMachine();

      expect(machine.transitionTo(DeathManStatus.monitoring),
          DeathManStatus.monitoring);
      expect(machine.current, DeathManStatus.monitoring);
    });

    test('allows monitoring to final confirmation', () {
      final machine = DeathManStateMachine(
        initialState: DeathManStatus.monitoring,
      );

      expect(
        machine.transitionTo(DeathManStatus.awaitingConfirmation),
        DeathManStatus.awaitingConfirmation,
      );
    });

    test('allows final confirmation to overdue', () {
      final machine = DeathManStateMachine(
        initialState: DeathManStatus.awaitingConfirmation,
      );

      expect(
        machine.transitionTo(DeathManStatus.overdue),
        DeathManStatus.overdue,
      );
    });

    test('allows final confirmation to confirmed safe', () {
      final machine = DeathManStateMachine(
        initialState: DeathManStatus.awaitingConfirmation,
      );

      expect(
        machine.transitionTo(DeathManStatus.confirmedSafe),
        DeathManStatus.confirmedSafe,
      );
    });

    test('allows final confirmation to cancelled', () {
      final machine = DeathManStateMachine(
        initialState: DeathManStatus.awaitingConfirmation,
      );

      expect(
        machine.transitionTo(DeathManStatus.cancelled),
        DeathManStatus.cancelled,
      );
    });

    test('allows cancellation before expiration', () {
      final machine = DeathManStateMachine();

      machine.transitionTo(DeathManStatus.monitoring);

      expect(machine.transitionTo(DeathManStatus.cancelled),
          DeathManStatus.cancelled);
    });

    test('allows overdue to escalated to expired', () {
      final machine = DeathManStateMachine(
        initialState: DeathManStatus.overdue,
      );

      expect(
        machine.transitionTo(DeathManStatus.escalated),
        DeathManStatus.escalated,
      );
      expect(
        machine.transitionTo(DeathManStatus.expired),
        DeathManStatus.expired,
      );
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

    test('rejects scheduled to overdue without monitoring and confirmation',
        () {
      final machine = DeathManStateMachine();

      expect(
        () => machine.transitionTo(DeathManStatus.overdue),
        throwsA(isA<DeathManException>()),
      );
      expect(machine.current, DeathManStatus.scheduled);
    });

    test('rejects terminal state mutation', () {
      final machine = DeathManStateMachine(
        initialState: DeathManStatus.cancelled,
      );

      expect(
        () => machine.transitionTo(DeathManStatus.monitoring),
        throwsA(isA<DeathManException>()),
      );
      expect(machine.current, DeathManStatus.cancelled);
    });
  });
}
