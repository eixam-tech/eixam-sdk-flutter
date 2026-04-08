import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../../mappers/local_state_serializers.dart';
import '../dtos/sos_incident_dto.dart';
import '../datasources_remote/sos_remote_data_source.dart';
import '../datasources_local/shared_prefs_sdk_store.dart';
import '../../sdk/operational_realtime_client.dart';
import '../../sdk/sdk_mqtt_contract.dart';
import 'mqtt_sos_lifecycle_update.dart';
import '../../mappers/sos_incident_mapper.dart';
import 'sos_runtime_rehydration_support.dart';

class MqttOperationalSosRepository
    implements SosRepository, SosRuntimeRehydrationSupport {
  MqttOperationalSosRepository({
    required this.realtimeClient,
    SosRemoteDataSource? remoteDataSource,
    this.cancelRemoteDataSource,
    SharedPrefsSdkStore? localStore,
    Duration destructiveRehydrationGracePeriod =
        const Duration(seconds: 5),
    DateTime Function()? nowProvider,
  })  : remoteDataSource = remoteDataSource ?? cancelRemoteDataSource,
        _localStore = localStore,
        _destructiveRehydrationGracePeriod = destructiveRehydrationGracePeriod,
        _nowProvider = nowProvider ?? DateTime.now {
    _stateController.add(_stateMachine.current);
    _realtimeSub = realtimeClient.watchEvents().listen(_handleRealtimeEvent);
  }

  final OperationalRealtimeClient realtimeClient;
  final SosRemoteDataSource? remoteDataSource;
  final SosRemoteDataSource? cancelRemoteDataSource;
  final SharedPrefsSdkStore? _localStore;
  final Duration _destructiveRehydrationGracePeriod;
  final DateTime Function() _nowProvider;
  final SosIncidentMapper _mapper = const SosIncidentMapper();
  SosStateMachine _stateMachine = SosStateMachine();
  final StreamController<SosState> _stateController =
      StreamController<SosState>.broadcast();

  StreamSubscription<RealtimeEvent>? _realtimeSub;
  SosIncident? _activeIncident;
  DateTime? _lastActiveLikeStateAt;

  Future<void> restoreState() async {
    if (_localStore == null) {
      return;
    }

    final incidentJson =
        await _localStore.readJson(SharedPrefsSdkStore.sosIncidentKey);
    final stateRaw =
        await _localStore.readString(SharedPrefsSdkStore.sosStateKey);

    if (incidentJson != null) {
      _activeIncident = LocalStateSerializers.sosIncidentFromJson(incidentJson);
      _lastActiveLikeStateAt = _activeIncident?.createdAt;
    }

    final restoredState = SosState.values.firstWhere(
      (value) => value.name == stateRaw,
      orElse: () => _activeIncident?.state ?? SosState.idle,
    );
    _setState(restoredState);
  }

  @override
  Future<SosIncident> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
  }) async {
    final current = _stateMachine.current;
    if (current != SosState.idle &&
        current != SosState.failed &&
        current != SosState.cancelled &&
        current != SosState.resolved) {
      throw const SosException(
        'E_SOS_ALREADY_ACTIVE',
        'There is already an SOS flow in progress',
      );
    }
    if (positionSnapshot == null) {
      throw const SosException(
        'E_SOS_POSITION_REQUIRED',
        'Operational SOS over MQTT requires a current location snapshot.',
      );
    }

    _emit(SosState.triggerRequested);
    _emit(SosState.triggeredLocal);
    _emit(SosState.sending);

    final incident = SosIncident(
      id: 'sos-${DateTime.now().microsecondsSinceEpoch}',
      state: SosState.sent,
      createdAt: DateTime.now().toUtc(),
      triggerSource: triggerSource,
      message: message,
      positionSnapshot: positionSnapshot,
    );

    try {
      await realtimeClient.publishOperationalSos(
        MqttOperationalSosRequest(
          timestamp: incident.createdAt,
          positionSnapshot: positionSnapshot,
        ),
      );
      _activeIncident = incident;
      _rememberActiveLikeState();
      _emit(SosState.sent);
      await _persistState();
      return incident;
    } catch (error) {
      _emit(SosState.failed);
      await _persistState();
      if (error is EixamSdkException) {
        rethrow;
      }
      throw SosException('E_SOS_TRIGGER_FAILED', error.toString());
    }
  }

  @override
  Future<SosIncident> cancelSos() async {
    if (!await _ensureActiveIncidentForCancellation()) {
      throw const SosException(
        'E_SOS_CANCEL_NOT_ALLOWED',
        'There is no active SOS to cancel',
      );
    }

    final remoteDataSource = cancelRemoteDataSource;
    if (remoteDataSource == null) {
      throw const SosException(
        'E_SOS_CANCEL_HTTP_UNAVAILABLE',
        'SOS cancellation requires an HTTP remote data source.',
      );
    }

    _activeIncident =
        _activeIncident!.copyWith(state: SosState.cancelRequested);
    _rememberActiveLikeState();
    _emit(SosState.cancelRequested);
    await _persistState();

    try {
      final cancelled = await remoteDataSource.cancelSos();
      final settledIncident = await _settleCancelledIncident(
        remoteDataSource: remoteDataSource,
        cancelledDto: cancelled,
      );
      await _persistState();
      return settledIncident;
    } catch (error) {
      _activeIncident = _activeIncident!.copyWith(state: SosState.sent);
      _emit(SosState.sent);
      await _persistState();
      if (error is EixamSdkException) {
        rethrow;
      }
      throw SosException('E_SOS_CANCEL_FAILED', error.toString());
    }
  }

  Future<SosIncident> _settleCancelledIncident({
    required SosRemoteDataSource remoteDataSource,
    required SosIncidentDto? cancelledDto,
  }) async {
    if (cancelledDto != null) {
      return _applyBackendIncident(cancelledDto);
    }

    final activeAfterCancel = await remoteDataSource.getActiveSos();
    if (activeAfterCancel != null) {
      return _applyBackendIncident(activeAfterCancel);
    }

    _activeIncident = _activeIncident!.copyWith(state: SosState.cancelled);
    _setState(SosState.cancelled);
    return _activeIncident!;
  }

  SosIncident _applyBackendIncident(SosIncidentDto dto) {
    _activeIncident = _mapper.toDomain(dto);
    if (_isActiveLikeState(_activeIncident!.state)) {
      _rememberActiveLikeState();
    }
    _setState(_activeIncident!.state);
    return _activeIncident!;
  }

  @override
  Future<SosIncident?> getCurrentIncident() async {
    try {
      await rehydrateRuntimeStateFromBackend();
    } catch (_) {
      // Keep the last known local incident when backend refresh is unavailable.
    }
    return _activeIncident;
  }

  @override
  Future<SosState> getSosState() async => _stateMachine.current;

  @override
  Stream<SosState> watchSosState() => _stateController.stream;

  @override
  Future<SosRuntimeRehydrationResult> rehydrateRuntimeStateFromBackend() async {
    final dataSource = remoteDataSource;
    if (dataSource == null) {
      return SosRuntimeRehydrationResult(
        outcome: SosRuntimeRehydrationOutcome.keptLocalFallback,
        resultingState: _stateMachine.current,
        diagnosticNote:
            'SOS rehydration skipped because no HTTP SOS data source is configured.',
      );
    }

    try {
      final active = await dataSource.getActiveSos();
      if (active == null) {
        if (_shouldPreserveLocalFallback()) {
          await _persistState();
          return SosRuntimeRehydrationResult(
            outcome: SosRuntimeRehydrationOutcome.keptLocalFallback,
            resultingState: _stateMachine.current,
            diagnosticNote:
                'Backend reported no active SOS during the short post-trigger '
                'consistency window; kept the recent local incident.',
          );
        }

        _activeIncident = null;
        _setState(SosState.idle);
        await _persistState();
        return const SosRuntimeRehydrationResult(
          outcome: SosRuntimeRehydrationOutcome.clearedToIdle,
          resultingState: SosState.idle,
        );
      }

      _activeIncident = _mapper.toDomain(active);
      _rememberActiveLikeStateIfNeeded(_activeIncident!.state);
      _setState(_activeIncident!.state);
      await _persistState();
      return SosRuntimeRehydrationResult(
        outcome: SosRuntimeRehydrationOutcome.hydratedFromBackend,
        resultingState: _stateMachine.current,
      );
    } catch (error) {
      return SosRuntimeRehydrationResult(
        outcome: SosRuntimeRehydrationOutcome.keptLocalFallback,
        resultingState: _stateMachine.current,
        diagnosticNote:
            'SOS rehydration failed; kept local fallback state. Error: $error',
      );
    }
  }

  Future<void> dispose() async {
    await _realtimeSub?.cancel();
    await _stateController.close();
  }

  void _handleRealtimeEvent(RealtimeEvent event) {
    final update = MqttSosLifecycleUpdate.fromRealtimeEvent(event);
    if (update == null || _activeIncident == null) {
      return;
    }
    if (update.incidentId != _activeIncident!.id) {
      return;
    }

    _activeIncident = _activeIncident!.copyWith(state: update.state);
    _rememberActiveLikeStateIfNeeded(update.state);
    _emit(update.state);
    unawaited(_persistState());
  }

  void _emit(SosState state) {
    _rememberActiveLikeStateIfNeeded(state);
    _stateMachine.transitionTo(state);
    _stateController.add(_stateMachine.current);
  }

  void _setState(SosState state) {
    _stateMachine = SosStateMachine();
    _restoreState(state);
    _stateController.add(_stateMachine.current);
  }

  void _restoreState(SosState state) {
    if (state == SosState.idle) {
      return;
    }

    final path = switch (state) {
      SosState.idle => const <SosState>[],
      SosState.arming => const <SosState>[SosState.arming],
      SosState.triggerRequested => const <SosState>[SosState.triggerRequested],
      SosState.triggeredLocal => const <SosState>[
          SosState.triggerRequested,
          SosState.triggeredLocal,
        ],
      SosState.sending => const <SosState>[
          SosState.triggerRequested,
          SosState.triggeredLocal,
          SosState.sending,
        ],
      SosState.sent => const <SosState>[
          SosState.triggerRequested,
          SosState.triggeredLocal,
          SosState.sending,
          SosState.sent,
        ],
      SosState.acknowledged => const <SosState>[
          SosState.triggerRequested,
          SosState.triggeredLocal,
          SosState.sending,
          SosState.sent,
          SosState.acknowledged,
        ],
      SosState.cancelRequested => const <SosState>[
          SosState.triggerRequested,
          SosState.triggeredLocal,
          SosState.sending,
          SosState.sent,
          SosState.cancelRequested,
        ],
      SosState.cancelled => const <SosState>[
          SosState.triggerRequested,
          SosState.triggeredLocal,
          SosState.sending,
          SosState.sent,
          SosState.cancelRequested,
          SosState.cancelled,
        ],
      SosState.resolved => const <SosState>[
          SosState.triggerRequested,
          SosState.triggeredLocal,
          SosState.sending,
          SosState.sent,
          SosState.resolved,
        ],
      SosState.failed => const <SosState>[
          SosState.triggerRequested,
          SosState.failed,
        ],
    };

    for (final next in path) {
      _stateMachine.transitionTo(next);
    }
  }

  Future<void> _persistState() async {
    if (_localStore == null) {
      return;
    }

    await _localStore.saveString(
      SharedPrefsSdkStore.sosStateKey,
      _stateMachine.current.name,
    );
    if (_activeIncident == null || _stateMachine.current == SosState.idle) {
      await _localStore.remove(SharedPrefsSdkStore.sosIncidentKey);
      return;
    }

    await _localStore.saveJson(
      SharedPrefsSdkStore.sosIncidentKey,
      LocalStateSerializers.sosIncidentToJson(_activeIncident!),
    );
  }

  Future<bool> _ensureActiveIncidentForCancellation() async {
    final current = _stateMachine.current;
    if (!_isInactiveForCancellation(current) && _activeIncident != null) {
      return true;
    }

    try {
      await rehydrateRuntimeStateFromBackend();
    } catch (_) {
      // Keep the best local fallback if recovery is unavailable.
    }

    final recoveredState = _stateMachine.current;
    return !_isInactiveForCancellation(recoveredState) &&
        _activeIncident != null;
  }

  bool _isInactiveForCancellation(SosState state) {
    return {
      SosState.idle,
      SosState.cancelled,
      SosState.resolved,
    }.contains(state);
  }

  bool _shouldPreserveLocalFallback() {
    if (_activeIncident == null || !_isActiveLikeState(_stateMachine.current)) {
      return false;
    }

    final lastActiveLikeStateAt = _lastActiveLikeStateAt;
    if (lastActiveLikeStateAt == null) {
      return false;
    }

    return _nowProvider().toUtc().difference(lastActiveLikeStateAt.toUtc()) <=
        _destructiveRehydrationGracePeriod;
  }

  bool _isActiveLikeState(SosState state) {
    return {
      SosState.arming,
      SosState.triggerRequested,
      SosState.triggeredLocal,
      SosState.sending,
      SosState.sent,
      SosState.acknowledged,
      SosState.cancelRequested,
    }.contains(state);
  }

  void _rememberActiveLikeState() {
    _lastActiveLikeStateAt = _nowProvider().toUtc();
  }

  void _rememberActiveLikeStateIfNeeded(SosState state) {
    if (_isActiveLikeState(state)) {
      _rememberActiveLikeState();
    }
  }
}
