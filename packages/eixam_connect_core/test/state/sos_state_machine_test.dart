import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  group('SosStateMachine', () {
    final validTransitions = <({SosState from, SosState to})>[
      (from: SosState.idle, to: SosState.arming),
      (from: SosState.idle, to: SosState.triggerRequested),
      (from: SosState.arming, to: SosState.triggerRequested),
      (from: SosState.arming, to: SosState.idle),
      (from: SosState.triggerRequested, to: SosState.triggeredLocal),
      (from: SosState.triggerRequested, to: SosState.failed),
      (from: SosState.triggeredLocal, to: SosState.sending),
      (from: SosState.triggeredLocal, to: SosState.cancelRequested),
      (from: SosState.sending, to: SosState.sent),
      (from: SosState.sending, to: SosState.failed),
      (from: SosState.sending, to: SosState.cancelRequested),
      (from: SosState.sent, to: SosState.acknowledged),
      (from: SosState.sent, to: SosState.cancelRequested),
      (from: SosState.sent, to: SosState.resolved),
      (from: SosState.acknowledged, to: SosState.resolved),
      (from: SosState.cancelRequested, to: SosState.cancelled),
      (from: SosState.cancelRequested, to: SosState.failed),
      (from: SosState.cancelled, to: SosState.idle),
      (from: SosState.resolved, to: SosState.idle),
      (from: SosState.failed, to: SosState.idle),
      (from: SosState.failed, to: SosState.triggerRequested),
    ];

    for (final transition in validTransitions) {
      test('allows ${transition.from.name} -> ${transition.to.name}', () {
        final machine = machineAt(transition.from);

        expect(
          SosStateMachine.canTransition(
            from: transition.from,
            to: transition.to,
          ),
          isTrue,
        );
        expect(machine.transitionTo(transition.to), transition.to);
        expect(machine.current, transition.to);
      });
    }

    final invalidTransitions = <({SosState from, SosState to})>[
      (from: SosState.idle, to: SosState.sent),
      (from: SosState.triggerRequested, to: SosState.sent),
      (from: SosState.sending, to: SosState.acknowledged),
      (from: SosState.acknowledged, to: SosState.idle),
      (from: SosState.resolved, to: SosState.triggerRequested),
      (from: SosState.cancelled, to: SosState.failed),
      (from: SosState.failed, to: SosState.resolved),
    ];

    for (final transition in invalidTransitions) {
      test('rejects ${transition.from.name} -> ${transition.to.name}', () {
        final machine = machineAt(transition.from);

        expect(
          SosStateMachine.canTransition(
            from: transition.from,
            to: transition.to,
          ),
          isFalse,
        );
        expect(
          () => machine.transitionTo(transition.to),
          throwsA(
            isA<SosException>().having(
              (error) => error.code,
              'code',
              'E_SOS_INVALID_TRANSITION',
            ),
          ),
        );
        expect(machine.current, transition.from);
      });
    }
  });
}

SosStateMachine machineAt(SosState state) {
  final machine = SosStateMachine();

  switch (state) {
    case SosState.idle:
      break;
    case SosState.arming:
      machine.transitionTo(SosState.arming);
    case SosState.triggerRequested:
      machine.transitionTo(SosState.triggerRequested);
    case SosState.triggeredLocal:
      machine
        ..transitionTo(SosState.triggerRequested)
        ..transitionTo(SosState.triggeredLocal);
    case SosState.sending:
      machine
        ..transitionTo(SosState.triggerRequested)
        ..transitionTo(SosState.triggeredLocal)
        ..transitionTo(SosState.sending);
    case SosState.sent:
      machine
        ..transitionTo(SosState.triggerRequested)
        ..transitionTo(SosState.triggeredLocal)
        ..transitionTo(SosState.sending)
        ..transitionTo(SosState.sent);
    case SosState.acknowledged:
      machine
        ..transitionTo(SosState.triggerRequested)
        ..transitionTo(SosState.triggeredLocal)
        ..transitionTo(SosState.sending)
        ..transitionTo(SosState.sent)
        ..transitionTo(SosState.acknowledged);
    case SosState.cancelRequested:
      machine
        ..transitionTo(SosState.triggerRequested)
        ..transitionTo(SosState.triggeredLocal)
        ..transitionTo(SosState.cancelRequested);
    case SosState.cancelled:
      machine
        ..transitionTo(SosState.triggerRequested)
        ..transitionTo(SosState.triggeredLocal)
        ..transitionTo(SosState.cancelRequested)
        ..transitionTo(SosState.cancelled);
    case SosState.resolved:
      machine
        ..transitionTo(SosState.triggerRequested)
        ..transitionTo(SosState.triggeredLocal)
        ..transitionTo(SosState.sending)
        ..transitionTo(SosState.sent)
        ..transitionTo(SosState.resolved);
    case SosState.failed:
      machine
        ..transitionTo(SosState.triggerRequested)
        ..transitionTo(SosState.failed);
  }

  expect(machine.current, state);
  return machine;
}
