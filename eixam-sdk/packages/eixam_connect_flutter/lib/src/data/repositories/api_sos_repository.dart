import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources/sos_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/mappers/sos_incident_mapper.dart';
import 'package:eixam_connect_flutter/src/storage/shared_prefs_sdk_store.dart';

/// SOS repository backed by a remote datasource.
///
/// It persists the last known SOS state locally so the SDK can recover
/// gracefully after app restart. Persisted state restoration is defensive and
/// never replays runtime transitions.
class ApiSosRepository implements SosRepository {
  ApiSosRepository({
    required SosRemoteDataSource remoteDataSource,
    required SharedPrefsSdkStore store,
  })  : _remoteDataSource = remoteDataSource,
        _store = store,
        _stateMachine = SosStateMachine();

  final SosRemoteDataSource _remoteDataSource;
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

      if (restoredState == SosState.idle) {
        _activeIncident = null;
        await _store.clearSosState();
        await _store.clearActiveSosIncident();
      } else {
        _activeIncident = rawIncident;
      }
    } catch (_) {
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

    try {
      final dto = await _remoteDataSource.triggerSos(
        input: input,
        positionSnapshot: positionSnapshot,
      );

      final incident = SosIncidentMapper.fromDto(dto);
      _activeIncident = incident;

      _stateMachine.markSent();
      await _persistCurrentState();
      _stateController.add(_stateMachine.state);

      return incident;
    } catch (e) {
      _stateMachine.fail();
      await _persistCurrentState();
      _stateController.add(_stateMachine.state);

      if (e is EixamSdkException) rethrow;

      throw EixamSdkException(
        code: 'E_SOS_TRIGGER_FAILED',
        message: e.toString(),
      );
    }
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

    try {
      final dto = await _remoteDataSource.cancelSos(
        sosId: _activeIncident!.id,
        input: input,
      );

      final incident = SosIncidentMapper.fromDto(dto);
      _activeIncident = incident;

      _stateMachine.markCancelled();
      await _persistCurrentState();
      _stateController.add(_stateMachine.state);

      return incident;
    } catch (e) {
      _stateMachine.fail();
      await _persistCurrentState();
      _stateController.add(_stateMachine.state);

      if (e is EixamSdkException) rethrow;

      throw EixamSdkException(
        code: 'E_SOS_CANCEL_FAILED',
        message: e.toString(),
      );
    }
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