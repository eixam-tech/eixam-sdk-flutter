import 'package:eixam_connect_core/src/errors/eixam_sdk_exception.dart';
import 'package:eixam_connect_core/src/sos_state.dart';

/// Manages the SOS state machine transitions.
///
/// Important:
/// - Runtime transitions must be validated.
/// - Restoring persisted state must NOT replay transitions.
/// - Persisted transitional states are sanitized before restore.
class SosStateMachine {
  SosState _state;

  SosStateMachine({SosState initialState = SosState.idle}) : _state = initialState;

  SosState get state => _state;

  /// Restores a previously persisted SOS state directly.
  ///
  /// This method does not replay transitions. It sanitizes the incoming state
  /// to avoid restoring volatile or incomplete transitional states after app restart.
  void restore(SosState restoredState) {
    _state = sanitizeRestoredSosState(restoredState);
  }

  /// Resets the machine to idle.
  void reset() {
    _state = SosState.idle;
  }

  void requestTrigger() {
    if (_state != SosState.idle) {
      throw const EixamSdkException(
        code: 'E_SOS_INVALID_TRANSITION',
        message: 'Invalid SOS state transition',
      );
    }
    _state = SosState.triggerRequested;
  }

  void markTriggeredLocal() {
    if (_state != SosState.triggerRequested) {
      throw const EixamSdkException(
        code: 'E_SOS_INVALID_TRANSITION',
        message: 'Invalid SOS state transition',
      );
    }
    _state = SosState.triggeredLocal;
  }

  void markSending() {
    if (_state != SosState.triggeredLocal) {
      throw const EixamSdkException(
        code: 'E_SOS_INVALID_TRANSITION',
        message: 'Invalid SOS state transition',
      );
    }
    _state = SosState.sending;
  }

  void markSent() {
    if (_state != SosState.sending) {
      throw const EixamSdkException(
        code: 'E_SOS_INVALID_TRANSITION',
        message: 'Invalid SOS state transition',
      );
    }
    _state = SosState.sent;
  }

  void acknowledge() {
    if (_state != SosState.sent) {
      throw const EixamSdkException(
        code: 'E_SOS_INVALID_TRANSITION',
        message: 'Invalid SOS state transition',
      );
    }
    _state = SosState.acknowledged;
  }

  void requestCancel() {
    if (_state != SosState.sent && _state != SosState.acknowledged) {
      throw const EixamSdkException(
        code: 'E_SOS_INVALID_TRANSITION',
        message: 'Invalid SOS state transition',
      );
    }
    _state = SosState.cancelRequested;
  }

  void markCancelled() {
    if (_state != SosState.cancelRequested) {
      throw const EixamSdkException(
        code: 'E_SOS_INVALID_TRANSITION',
        message: 'Invalid SOS state transition',
      );
    }
    _state = SosState.cancelled;
  }

  void resolve() {
    if (_state != SosState.sent &&
        _state != SosState.acknowledged &&
        _state != SosState.cancelled) {
      throw const EixamSdkException(
        code: 'E_SOS_INVALID_TRANSITION',
        message: 'Invalid SOS state transition',
      );
    }
    _state = SosState.resolved;
  }

  void fail() {
    _state = SosState.failed;
  }
}

/// Restores only stable states.
///
/// Transitional states should not survive app restart because they represent
/// an in-flight process that may have been interrupted.
SosState sanitizeRestoredSosState(SosState state) {
  switch (state) {
    case SosState.arming:
    case SosState.triggerRequested:
    case SosState.triggeredLocal:
    case SosState.sending:
    case SosState.cancelRequested:
      return SosState.idle;

    case SosState.idle:
    case SosState.sent:
    case SosState.acknowledged:
    case SosState.cancelled:
    case SosState.resolved:
    case SosState.failed:
      return state;
  }
}