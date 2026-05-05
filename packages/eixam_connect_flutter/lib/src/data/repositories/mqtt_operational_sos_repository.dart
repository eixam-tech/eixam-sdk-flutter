import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../../device/ble_debug_registry.dart';
import '../../mappers/local_state_serializers.dart';
import '../../mappers/sos_incident_mapper.dart';
import '../../sdk/operational_realtime_client.dart';
import '../../sdk/sdk_mqtt_contract.dart';
import '../../sdk/sos_backend_identity_normalizer.dart';
import '../datasources_local/shared_prefs_sdk_store.dart';
import '../datasources_remote/sos_remote_data_source.dart';
import '../dtos/sos_incident_dto.dart';
import 'mqtt_sos_lifecycle_update.dart';
import 'sos_runtime_rehydration_support.dart';

class MqttOperationalSosRepository
    implements SosRepository, SosRuntimeRehydrationSupport {
  MqttOperationalSosRepository({
    required this.realtimeClient,
    SosRemoteDataSource? remoteDataSource,
    this.cancelRemoteDataSource,
    SharedPrefsSdkStore? localStore,
    Duration destructiveRehydrationGracePeriod = const Duration(seconds: 5),
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
    String? deviceId,
    String? appDeviceId,
    String? hardwareId,
    int? originatorNodeId,
    int? relayNodeId,
    String? relayDeviceId,
    String? relayHardwareId,
    String? relaySource,
    String? incidentId,
    String? cycleKey,
    SdkDeviceBatterySnapshot? deviceBattery,
    SdkCoverageSnapshot? deviceCoverage,
    int? mobileBattery,
    SdkCoverageSnapshot? mobileCoverage,
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
      await submitSosToBackend(
        timestamp: incident.createdAt,
        positionSnapshot: positionSnapshot,
        deviceId: deviceId,
        appDeviceId: appDeviceId,
        hardwareId: hardwareId,
        originatorNodeId: originatorNodeId,
        relayNodeId: relayNodeId,
        relayDeviceId: relayDeviceId,
        relayHardwareId: relayHardwareId,
        relaySource: relaySource,
        incidentId: incidentId ?? incident.id,
        cycleKey: cycleKey,
        deviceBattery: deviceBattery,
        deviceCoverage: deviceCoverage,
        mobileBattery: mobileBattery,
        mobileCoverage: mobileCoverage,
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

  Future<void> submitSosToBackend({
    required DateTime timestamp,
    required TrackingPosition? positionSnapshot,
    String? deviceId,
    String? appDeviceId,
    String? hardwareId,
    int? originatorNodeId,
    int? relayNodeId,
    String? relayDeviceId,
    String? relayHardwareId,
    String? relaySource,
    String? incidentId,
    String? cycleKey,
    SdkDeviceBatterySnapshot? deviceBattery,
    SdkCoverageSnapshot? deviceCoverage,
    int? mobileBattery,
    SdkCoverageSnapshot? mobileCoverage,
  }) {
    final identity = normalizeSosBackendIdentity(
      deviceId: deviceId,
      appDeviceId: appDeviceId,
      originatorNodeId: originatorNodeId,
      relayNodeId: relayNodeId,
      relayDeviceId: relayDeviceId,
      incidentId: incidentId,
      cycleKey: cycleKey,
      hardwareId: hardwareId,
    );
    if (identity.hardwareId != null) {
      BleDebugRegistry.instance.recordEvent(
        'BACKEND_DEVICE_ID_NORMALIZED previousDeviceId=$deviceId '
        'normalizedDeviceId=${identity.deviceId} source=sos',
      );
    }
    if (isBleMacDeviceId(identity.deviceId)) {
      BleDebugRegistry.instance.recordEvent(
        'BACKEND_DEVICE_ID_INVALID invalidBackendDeviceId=${identity.deviceId} source=sos',
      );
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_BACKEND_PAYLOAD_FINAL source=mqtt '
      'owner=${identity.originatorNodeId == null ? "app" : "device"} '
      'triggerSource=${relaySource ?? "mqtt_operational_sos"} '
      'deviceId=${identity.deviceId ?? "none"} '
      'nodeId=${identity.nodeId?.toString() ?? "none"} '
      'appDeviceId=${identity.appDeviceId ?? "none"} '
      'originatorNodeId=${identity.originatorNodeId?.toString() ?? "none"} '
      'relayNodeId=${relayNodeId?.toString() ?? "none"} '
      'relayDeviceId=${identity.relayDeviceId ?? "none"} '
      'hardwareId=${identity.hardwareId ?? "none"} '
      'relayHardwareId=${relayHardwareId ?? "none"} '
      'identitySource=${identity.identitySource} '
      'incidentId=${incidentId ?? "none"} '
      'cycleKey=${cycleKey ?? "none"}',
    );
    return realtimeClient.publishOperationalSos(
      MqttOperationalSosRequest(
        timestamp: timestamp,
        positionSnapshot: positionSnapshot,
        deviceId: identity.deviceId,
        appDeviceId: identity.appDeviceId,
        hardwareId: identity.hardwareId,
        identitySource: identity.identitySource,
        originatorNodeId: identity.originatorNodeId,
        relayNodeId: relayNodeId,
        relayDeviceId: identity.relayDeviceId,
        relayHardwareId: relayHardwareId,
        source: relaySource,
        incidentId: incidentId,
        cycleKey: cycleKey,
        deviceBattery: deviceBattery,
        deviceCoverage: deviceCoverage,
        mobileBattery: mobileBattery,
        mobileCoverage: mobileCoverage,
      ),
    );
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

  @override
  Future<SosIncident> resolveSos() async {
    if (!await _ensureActiveIncidentForCancellation()) {
      throw const SosException(
        'E_SOS_RESOLVE_NOT_ALLOWED',
        'There is no active SOS to resolve',
      );
    }

    final remoteDataSource = cancelRemoteDataSource;
    if (remoteDataSource == null) {
      throw const SosException(
        'E_SOS_RESOLVE_HTTP_UNAVAILABLE',
        'SOS resolve requires an HTTP remote data source.',
      );
    }

    try {
      final resolved = await remoteDataSource.resolveSos();
      final settledIncident = await _settleResolvedIncident(
        remoteDataSource: remoteDataSource,
        resolvedDto: resolved,
      );
      await _persistState();
      return settledIncident;
    } catch (error) {
      if (error is EixamSdkException) {
        rethrow;
      }
      throw SosException('E_SOS_RESOLVE_FAILED', error.toString());
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

  Future<SosIncident> _settleResolvedIncident({
    required SosRemoteDataSource remoteDataSource,
    required SosIncidentDto? resolvedDto,
  }) async {
    if (resolvedDto != null) {
      return _applyBackendIncident(resolvedDto);
    }

    final activeAfterResolve = await remoteDataSource.getActiveSos();
    if (activeAfterResolve != null) {
      return _applyBackendIncident(activeAfterResolve);
    }

    _activeIncident = _activeIncident!.copyWith(state: SosState.resolved);
    _setState(SosState.resolved);
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
  Future<SosHistoryPage> listSosHistory(
      {String? cursor, int limit = 20}) async {
    final dataSource = remoteDataSource;
    if (dataSource == null) {
      return const SosHistoryPage(items: [], hasMore: false);
    }
    return dataSource.listSosHistory(cursor: cursor, limit: limit).then((dto) {
      return SosHistoryPage(
        items: dto.items.map((item) {
          final incident = _mapper.toDomain(item.incident);
          return SosHistoryItem(
            id: incident.id,
            state: incident.state,
            createdAt: incident.createdAt,
            positionSnapshot: incident.positionSnapshot,
            triggerSource: incident.triggerSource,
            message: incident.message,
            deliveryChannel: incident.deliveryChannel,
            creationTelemetry: item.creationTelemetry == null
                ? null
                : SosHistoryTelemetry(
                    id: item.creationTelemetry!.id,
                    occurredAt:
                        DateTime.parse(item.creationTelemetry!.occurredAt),
                    latitude: item.creationTelemetry!.latitude,
                    longitude: item.creationTelemetry!.longitude,
                    altitude: item.creationTelemetry!.altitude,
                    deviceBattery: item.creationTelemetry!.deviceBattery,
                    deviceCoverage: item.creationTelemetry!.deviceCoverage,
                    mobileBattery: item.creationTelemetry!.mobileBattery,
                    mobileCoverage: item.creationTelemetry!.mobileCoverage,
                  ),
            trail: item.trail
                .map((p) => TrackingPosition(
                      latitude: p.latitude,
                      longitude: p.longitude,
                      timestamp: DateTime.parse(p.occurredAt),
                      altitude: p.altitude,
                      source: DeliveryMode.mobile,
                    ))
                .toList(),
          );
        }).toList(),
        nextCursor: dto.nextCursor,
        hasMore: dto.hasMore,
      );
    });
  }

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

    final previousIncident = _activeIncident;
    final nextIncident = previousIncident!.copyWith(state: update.state);
    final accepted = _emit(
      update.state,
      previousIncident: previousIncident,
      incomingIncident: nextIncident,
      reason: 'realtime_event',
    );
    if (!accepted) {
      return;
    }
    _activeIncident = nextIncident;
    _rememberActiveLikeStateIfNeeded(update.state);
    unawaited(_persistState());
  }

  bool _emit(
    SosState state, {
    SosIncident? previousIncident,
    SosIncident? incomingIncident,
    String reason = 'emit',
  }) {
    final previousState = _stateMachine.current;
    if (previousState == state) {
      return false;
    }
    try {
      _stateMachine.transitionTo(state);
      _rememberActiveLikeStateIfNeeded(state);
      _stateController.add(_stateMachine.current);
      return true;
    } on EixamSdkException catch (error) {
      if (error.code != 'E_SOS_INVALID_TRANSITION') {
        rethrow;
      }
      final accepted = _handleInvalidTransition(
        previousState: previousState,
        incomingState: state,
        previousIncident: previousIncident ?? _activeIncident,
        incomingIncident: incomingIncident,
        reason: reason,
      );
      if (accepted) {
        _rememberActiveLikeStateIfNeeded(state);
      }
      return accepted;
    }
  }

  bool _handleInvalidTransition({
    required SosState previousState,
    required SosState incomingState,
    required SosIncident? previousIncident,
    required SosIncident? incomingIncident,
    required String reason,
  }) {
    final previousTerminal = _terminalLabel(previousState);
    final incomingTerminal = _terminalLabel(incomingState);
    if (_isTerminalState(previousState) && _isActiveLikeState(incomingState)) {
      _logTransitionGuard(
        decision: 'ignore_invalid_transition',
        previousState: previousState,
        incomingState: incomingState,
        previousIncident: previousIncident,
        incomingIncident: incomingIncident,
        reason: 'stale_open_after_terminal:$reason',
      );
      return false;
    }
    if (_isTerminalState(incomingState) || incomingState == SosState.cancelRequested) {
      _setState(incomingState);
      return true;
    }
    _logTransitionGuard(
      decision: 'ignore_invalid_transition',
      previousState: previousState,
      incomingState: incomingState,
      previousIncident: previousIncident,
      incomingIncident: incomingIncident,
      reason: 'invalid_state_machine_transition:$reason '
          'previousTerminal=$previousTerminal incomingTerminal=$incomingTerminal',
    );
    return false;
  }

  void _logTransitionGuard({
    required String decision,
    required SosState previousState,
    required SosState incomingState,
    required SosIncident? previousIncident,
    required SosIncident? incomingIncident,
    required String reason,
  }) {
    BleDebugRegistry.instance.recordEvent(
      '[SOS_REPOSITORY_TRANSITION_GUARD] decision=$decision '
      'previousStage=${previousState.name} incomingStage=${incomingState.name} '
      'previousTerminal=${_terminalLabel(previousState)} '
      'incomingTerminal=${_terminalLabel(incomingState)} '
      'previousIncident=${previousIncident?.id ?? "none"} '
      'incomingIncident=${incomingIncident?.id ?? "none"} '
      'reason=$reason',
    );
  }

  String _terminalLabel(SosState state) {
    if (state == SosState.resolved) {
      return 'resolved';
    }
    if (state == SosState.cancelled) {
      return 'cancelled';
    }
    if (state == SosState.idle || state == SosState.failed) {
      return 'idle';
    }
    return 'open';
  }

  bool _isTerminalState(SosState state) {
    return state == SosState.resolved || state == SosState.cancelled;
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
