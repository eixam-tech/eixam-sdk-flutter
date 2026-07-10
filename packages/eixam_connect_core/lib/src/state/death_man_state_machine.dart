import '../enums/death_man_status.dart';
import '../errors/eixam_sdk_exception.dart';

class DeathManStateMachine {
  DeathManStateMachine({
    DeathManStatus initialState = DeathManStatus.scheduled,
  }) : _state = initialState;

  DeathManStatus _state;

  DeathManStatus get current => _state;

  DeathManStatus transitionTo(DeathManStatus next) {
    final allowed = switch (_state) {
      DeathManStatus.scheduled => {
          DeathManStatus.monitoring,
          DeathManStatus.cancelled
        },
      DeathManStatus.monitoring => {
          DeathManStatus.awaitingConfirmation,
          DeathManStatus.cancelled
        },
      DeathManStatus.awaitingConfirmation => {
          DeathManStatus.overdue,
          DeathManStatus.confirmedSafe,
          DeathManStatus.cancelled,
        },
      DeathManStatus.overdue => {DeathManStatus.escalated},
      DeathManStatus.escalated => {DeathManStatus.expired},
      DeathManStatus.confirmedSafe => <DeathManStatus>{},
      DeathManStatus.cancelled => <DeathManStatus>{},
      DeathManStatus.expired => <DeathManStatus>{},
    };

    if (!allowed.contains(next)) {
      throw const DeathManException('E_DEATH_MAN_INVALID_TRANSITION',
          'Invalid Death Man state transition');
    }

    _state = next;
    return _state;
  }
}
