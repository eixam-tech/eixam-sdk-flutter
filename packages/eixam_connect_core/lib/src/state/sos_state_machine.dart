import '../enums/sos_state.dart';
import '../errors/eixam_sdk_exception.dart';

class SosStateMachine {
  SosState _state = SosState.idle;

  SosState get current => _state;

  SosState transitionTo(SosState next) {
    final allowed = switch (_state) {
      SosState.idle => {SosState.arming, SosState.triggerRequested},
      SosState.arming => {SosState.triggerRequested, SosState.idle},
      SosState.triggerRequested => {SosState.triggeredLocal, SosState.failed},
      SosState.triggeredLocal => {SosState.sending, SosState.cancelRequested},
      SosState.sending => {
          SosState.sent,
          SosState.failed,
          SosState.cancelRequested
        },
      SosState.sent => {
          SosState.acknowledged,
          SosState.cancelRequested,
          SosState.resolved
        },
      SosState.acknowledged => {SosState.resolved},
      SosState.cancelRequested => {SosState.cancelled, SosState.failed},
      SosState.cancelled => {SosState.idle},
      SosState.resolved => {SosState.idle},
      SosState.failed => {SosState.idle, SosState.triggerRequested},
    };

    if (!allowed.contains(next)) {
      throw const SosException(
          'E_SOS_INVALID_TRANSITION', 'Invalid SOS state transition');
    }

    _state = next;
    return _state;
  }
}
