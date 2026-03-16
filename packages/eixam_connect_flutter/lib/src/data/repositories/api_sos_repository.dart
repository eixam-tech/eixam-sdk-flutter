import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../../mappers/local_state_serializers.dart';
import '../../mappers/sos_incident_mapper.dart';
import '../datasources_local/shared_prefs_sdk_store.dart';
import '../datasources_remote/sos_remote_data_source.dart';

/// SOS repository backed by a remote data source.
///
/// The repository keeps a local state machine for responsive UI updates and can
/// optionally cache the active incident so the host app restores context after a
/// process restart.
class ApiSosRepository implements SosRepository {
  ApiSosRepository({
    required this.remoteDataSource,
    this.mapper = const SosIncidentMapper(),
    SharedPrefsSdkStore? localStore,
  }) : _localStore = localStore {
    _stateController.add(_stateMachine.current);
  }

  final SosRemoteDataSource remoteDataSource;
  final SosIncidentMapper mapper;
  final SharedPrefsSdkStore? _localStore;

  final SosStateMachine _stateMachine = SosStateMachine();
  final StreamController<SosState> _stateController = StreamController<SosState>.broadcast();

  SosIncident? _activeIncident;

  /// Restores the latest cached incident and state from local storage.
  Future<void> restoreState() async {
    if (_localStore == null) return;

    final incidentJson = await _localStore.readJson(SharedPrefsSdkStore.sosIncidentKey);
    final stateRaw = await _localStore.readString(SharedPrefsSdkStore.sosStateKey);

    if (incidentJson != null) {
      _activeIncident = LocalStateSerializers.sosIncidentFromJson(incidentJson);
    }

    final restoredState = SosState.values.firstWhere(
      (value) => value.name == stateRaw,
      orElse: () => _activeIncident?.state ?? SosState.idle,
    );
    _emit(restoredState);
  }

  @override
  Future<SosIncident> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
  }) async {
    final current = _stateMachine.current;
    if (current != SosState.idle && current != SosState.failed && current != SosState.cancelled && current != SosState.resolved) {
      throw const SosException('E_SOS_ALREADY_ACTIVE', 'There is already an SOS flow in progress');
    }

    _emit(SosState.triggerRequested);
    _emit(SosState.triggeredLocal);
    _emit(SosState.sending);

    try {
      final dto = await remoteDataSource.triggerSos(
        message: message,
        triggerSource: triggerSource,
        positionSnapshot: positionSnapshot,
      );
      _activeIncident = mapper.toDomain(dto);
      _emit(_activeIncident!.state);
      await _persistState();
      return _activeIncident!;
    } catch (e) {
      _emit(SosState.failed);
      await _persistState();
      if (e is EixamSdkException) rethrow;
      throw SosException('E_SOS_TRIGGER_FAILED', e.toString());
    }
  }

  @override
  Future<SosIncident> cancelSos({String? reason}) async {
    final current = _stateMachine.current;
    if ({SosState.idle, SosState.cancelled, SosState.resolved}.contains(current) || _activeIncident == null) {
      throw const SosException('E_SOS_CANCEL_NOT_ALLOWED', 'There is no active SOS to cancel');
    }

    _emit(SosState.cancelRequested);

    try {
      final dto = await remoteDataSource.cancelSos(
        incidentId: _activeIncident!.id,
        reason: reason,
      );
      _activeIncident = mapper.toDomain(dto);
      _emit(_activeIncident!.state);
      await _persistState();
      return _activeIncident!;
    } catch (e) {
      _emit(SosState.failed);
      await _persistState();
      if (e is EixamSdkException) rethrow;
      throw SosException('E_SOS_CANCEL_FAILED', e.toString());
    }
  }

  @override
  Future<SosState> getSosState() async {
    try {
      final active = await remoteDataSource.getActiveSos();
      if (active == null) {
        _activeIncident = null;
        _emit(SosState.idle);
        await _persistState();
        return SosState.idle;
      }
      _activeIncident = mapper.toDomain(active);
      _emit(_activeIncident!.state);
      await _persistState();
      return _stateMachine.current;
    } catch (_) {
      return _stateMachine.current;
    }
  }

  @override
  Stream<SosState> watchSosState() => _stateController.stream;

  void _emit(SosState state) {
    _stateMachine.transitionTo(state);
    _stateController.add(_stateMachine.current);
  }

  Future<void> _persistState() async {
    if (_localStore == null) return;

    await _localStore.saveString(SharedPrefsSdkStore.sosStateKey, _stateMachine.current.name);
    if (_activeIncident == null || _stateMachine.current == SosState.idle) {
      await _localStore.remove(SharedPrefsSdkStore.sosIncidentKey);
      return;
    }

    await _localStore.saveJson(
      SharedPrefsSdkStore.sosIncidentKey,
      LocalStateSerializers.sosIncidentToJson(_activeIncident!),
    );
  }
}
