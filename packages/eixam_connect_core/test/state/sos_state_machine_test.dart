import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  group('SosStateMachine', () {
    test('allows the happy path from idle to resolved and back to idle', () {
      final machine = SosStateMachine();

      expect(machine.transitionTo(SosState.triggerRequested),
          SosState.triggerRequested);
      expect(machine.transitionTo(SosState.triggeredLocal),
          SosState.triggeredLocal);
      expect(machine.transitionTo(SosState.sending), SosState.sending);
      expect(machine.transitionTo(SosState.sent), SosState.sent);
      expect(
          machine.transitionTo(SosState.acknowledged), SosState.acknowledged);
      expect(machine.transitionTo(SosState.resolved), SosState.resolved);
      expect(machine.transitionTo(SosState.idle), SosState.idle);
    });

    test('allows cancellation from an active flow', () {
      final machine = SosStateMachine();

      machine.transitionTo(SosState.triggerRequested);
      machine.transitionTo(SosState.triggeredLocal);
      machine.transitionTo(SosState.cancelRequested);

      expect(machine.transitionTo(SosState.cancelled), SosState.cancelled);
      expect(machine.transitionTo(SosState.idle), SosState.idle);
    });

    test('rejects invalid transitions', () {
      final machine = SosStateMachine();

      expect(
        () => machine.transitionTo(SosState.sent),
        throwsA(
          isA<SosException>().having(
            (error) => error.code,
            'code',
            'E_SOS_INVALID_TRANSITION',
          ),
        ),
      );
      expect(machine.current, SosState.idle);
    });
  });
}
