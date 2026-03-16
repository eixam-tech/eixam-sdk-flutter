import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/storage/local_state_serializers.dart';
import 'package:eixam_connect_flutter/src/storage/shared_prefs_sdk_store.dart';

/// In-memory SOS repository with local persistence support.
///
/// This repository is useful for demos, local development and UI validation.
/// It persists the last SOS state and active incident so app restarts do not
/// lose critical context.
class InMemorySosRepository implements SosRepository {
  InMemorySosRepository({
    required SharedPrefsSdkStore store,
  })  : _store = store,
        _stateMachine = SosStateMachine();

  final SharedPrefsSdkStore _store;
  final SosStateMachine _stateMachine;

  final StreamController<SosState> _stateController =
      StreamController<SosState>.broadcast();

  SosIncident? _activeIncident;

  @override
  Future<void> restoreState() async {
    try {
      final rawState = await _store.readSosState();
      final rawIncident = await _store.readActiveSosIncident();

      final restoredState = rawState == null
          ? SosState.idle
          : sanitizeRestoredSosState(rawState);

      _stateMachine.restore(restoredState);

      // Keep active incident only for stable non-idle states.
      if (restoredState == SosState.idle) {
        _activeIncident = null;
        await _store.clearSosState();
        await _store.clearActiveSosIncident();
      } else {
        _activeIncident = rawIncident;
      }
    } catch (_) {
      // Never allow persisted corruption to kill bootstrap.
      _stateMachine.reset();
      _activeIncident = null;
      await _store.clearSosState();
      await _store.clearActiveSosIncident();
    }

    _stateController.add(_stateMachine.state);
  }

  @override
  Future<SosIncident> triggerSos({
    TriggerSosInput? input,
    TrackingPosition? positionSnapshot,
  }) async {
    _stateMachine.requestTrigger();
    _stateMachine.markTriggeredLocal();
    _stateMachine.markSending();

    final now = DateTime.now();

    final incident = SosIncident(
      id: 'sos_${now.millisecondsSinceEpoch}',
      state: SosState.sent,
      createdAt: now,
      updatedAt: now,
      triggerSource: input?.triggerSource ?? 'button_ui',
      message: input?.message,
      positionSnapshot: positionSnapshot,
    );

    _activeIncident = incident;

    _stateMachine.markSent();
    await _persistCurrentState();
    _stateController.add(_stateMachine.state);

    return incident;
  }

  @override
  Future<SosIncident> cancelSos({
    required CancelSosInput input,
  }) async {
    if (_activeIncident == null) {
      throw const EixamSdkException(
        code: 'E_SOS_NO_ACTIVE_INCIDENT',
        message: 'No active SOS incident found',
      );
    }

    _stateMachine.requestCancel();
    _stateMachine.markCancelled();

    final now = DateTime.now();

    _activeIncident = _activeIncident!.copyWith(
      state: SosState.cancelled,
      updatedAt: now,
      cancelReason: input.reason,
    );

    await _persistCurrentState();
    _stateController.add(_stateMachine.state);

    return _activeIncident!;
  }

  @override
  Future<SosState> getSosState() async {
    return _stateMachine.state;
  }

  @override
  Stream<SosState> watchSosState() {
    return _stateController.stream;
  }

  @override
  Future<SosIncident?> getActiveSos() async {
    return _activeIncident;
  }

  Future<void> _persistCurrentState() async {
    await _store.writeSosState(_stateMachine.state);

    if (_activeIncident == null) {
      await _store.clearActiveSosIncident();
      return;
    }

    await _store.writeActiveSosIncident(_activeIncident!);
  }

  @override
  Future<void> dispose() async {
    await _stateController.close();
  }
}