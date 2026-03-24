import '../entities/death_man_plan.dart';
import '../enums/death_man_status.dart';
import '../errors/eixam_sdk_exception.dart';

class DeathManStateMachine {
  DeathManStatus _state = DeathManStatus.scheduled;

  DeathManStatus get current => _state;

  DeathManStatus transitionTo(DeathManStatus next) {
    final allowed = switch (_state) {
      DeathManStatus.scheduled => {
          DeathManStatus.monitoring,
          DeathManStatus.cancelled
        },
      DeathManStatus.monitoring => {
          DeathManStatus.overdue,
          DeathManStatus.confirmedSafe,
          DeathManStatus.cancelled
        },
      DeathManStatus.overdue => {
          DeathManStatus.awaitingConfirmation,
          DeathManStatus.escalated
        },
      DeathManStatus.awaitingConfirmation => {
          DeathManStatus.confirmedSafe,
          DeathManStatus.escalated,
          DeathManStatus.expired
        },
      DeathManStatus.confirmedSafe => {DeathManStatus.expired},
      DeathManStatus.escalated => {DeathManStatus.expired},
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
