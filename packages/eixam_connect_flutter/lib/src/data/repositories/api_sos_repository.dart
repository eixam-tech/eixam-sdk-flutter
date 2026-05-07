import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../../device/ble_debug_registry.dart';
import '../../mappers/local_state_serializers.dart';
import '../../mappers/sos_incident_mapper.dart';
import '../datasources_local/shared_prefs_sdk_store.dart';
import '../datasources_remote/sos_remote_data_source.dart';
import 'sos_runtime_rehydration_support.dart';

/// SOS repository backed by a remote data source.
///
/// The repository keeps a local state machine for responsive UI updates and can
/// optionally cache the active incident so the host app restores context after a
/// process restart.
class ApiSosRepository implements SosRepository, SosRuntimeRehydrationSupport {
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

  SosStateMachine _stateMachine = SosStateMachine();
  final StreamController<SosState> _stateController =
      StreamController<SosState>.broadcast();

  SosIncident? _activeIncident;

  /// Restores the latest cached incident and state from local storage.
  Future<void> restoreState() async {
    if (_localStore == null) return;

    final incidentJson =
        await _localStore.readJson(SharedPrefsSdkStore.sosIncidentKey);
    final stateRaw =
        await _localStore.readString(SharedPrefsSdkStore.sosStateKey);

    if (incidentJson != null) {
      _activeIncident = LocalStateSerializers.sosIncidentFromJson(incidentJson);
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
          'E_SOS_ALREADY_ACTIVE', 'There is already an SOS flow in progress');
    }

    _emit(SosState.triggerRequested);
    _emit(SosState.triggeredLocal);
    _emit(SosState.sending);

    final publishStopwatch = Stopwatch()..start();
    try {
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] api_repository_trigger_entry '
        'state=sent deviceId=${deviceId ?? "none"} '
        'nodeId=${originatorNodeId?.toString() ?? "none"} '
        'hardwareId=${hardwareId ?? "none"} '
        'appDeviceId=${appDeviceId ?? "none"} '
        'hasLocation=${positionSnapshot != null}',
      );
      final dto = await remoteDataSource.triggerSos(
        message: message,
        triggerSource: triggerSource,
        positionSnapshot: positionSnapshot,
        deviceId: deviceId,
        appDeviceId: appDeviceId,
        hardwareId: hardwareId,
        originatorNodeId: originatorNodeId,
        relayNodeId: relayNodeId,
        relayDeviceId: relayDeviceId,
        relayHardwareId: relayHardwareId,
        relaySource: relaySource,
        incidentId: incidentId,
        cycleKey: cycleKey,
        deviceBattery: deviceBattery,
        deviceCoverage: deviceCoverage,
        mobileBattery: mobileBattery,
        mobileCoverage: mobileCoverage,
      );
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] api_repository_trigger_returned '
        'state=sent resultType=${dto.runtimeType} '
        'backendIncidentId=${dto.id} httpStatus=${dto.statusCode?.toString() ?? "none"}',
      );
      _activeIncident = mapper.toDomain(dto);
      _emit(_activeIncident!.state);
      await _persistState();
      return _activeIncident!;
    } catch (e) {
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] api_repository_trigger_failed '
        'state=sent errorType=${e.runtimeType} message=${_compactSummary(e)}',
      );
      _emit(SosState.failed);
      await _persistState();
      if (e is EixamSdkException) rethrow;
      throw SosException('E_SOS_TRIGGER_FAILED', e.toString());
    } finally {
      publishStopwatch.stop();
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] api_repository_trigger_finally '
        'state=sent elapsedMs=${publishStopwatch.elapsedMilliseconds}',
      );
    }
  }

  @override
  Future<SosIncident> cancelSos() async {
    final current = _stateMachine.current;
    if ({SosState.idle, SosState.cancelled, SosState.resolved}
            .contains(current) ||
        _activeIncident == null) {
      throw const SosException(
          'E_SOS_CANCEL_NOT_ALLOWED', 'There is no active SOS to cancel');
    }

    _emit(SosState.cancelRequested);

    try {
      final dto = await remoteDataSource.cancelSos();
      if (dto == null) {
        _activeIncident = _activeIncident!.copyWith(state: SosState.cancelled);
      } else {
        _activeIncident = mapper.toDomain(dto);
      }
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
  Future<SosIncident> resolveSos() async {
    final current = _stateMachine.current;
    if ({SosState.idle, SosState.cancelled, SosState.resolved}
            .contains(current) ||
        _activeIncident == null) {
      throw const SosException(
          'E_SOS_RESOLVE_NOT_ALLOWED', 'There is no active SOS to resolve');
    }

    try {
      final dto = await remoteDataSource.resolveSos();
      if (dto == null) {
        _activeIncident = _activeIncident!.copyWith(state: SosState.resolved);
      } else {
        _activeIncident = mapper.toDomain(dto);
      }
      _emit(_activeIncident!.state);
      await _persistState();
      return _activeIncident!;
    } catch (e) {
      _emit(SosState.failed);
      await _persistState();
      if (e is EixamSdkException) rethrow;
      throw SosException('E_SOS_RESOLVE_FAILED', e.toString());
    }
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
  Future<SosState> getSosState() async {
    try {
      final result = await rehydrateRuntimeStateFromBackend();
      return result.resultingState;
    } catch (_) {
      return _stateMachine.current;
    }
  }

  @override
  Stream<SosState> watchSosState() => _stateController.stream;

  @override
  Future<SosHistoryPage> listSosHistory(
      {String? cursor, int limit = 20}) async {
    final dto =
        await remoteDataSource.listSosHistory(cursor: cursor, limit: limit);
    return SosHistoryPage(
      items: dto.items.map((item) {
        final incident = mapper.toDomain(item.incident);
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
  }

  @override
  Future<SosRuntimeRehydrationResult> rehydrateRuntimeStateFromBackend() async {
    final active = await remoteDataSource.getActiveSos();
    if (active == null) {
      if (_shouldPreserveOpenIncidentWithoutBackendPayload()) {
        await _persistState();
        return SosRuntimeRehydrationResult(
          outcome: SosRuntimeRehydrationOutcome.keptLocalFallback,
          resultingState: _stateMachine.current,
          diagnosticNote:
              'Backend returned no active SOS payload while the local incident '
              'is still open; preserved it so cancellation can target the '
              'known incident id.',
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

    _activeIncident = mapper.toDomain(active);
    _setState(_activeIncident!.state);
    await _persistState();
    return SosRuntimeRehydrationResult(
      outcome: SosRuntimeRehydrationOutcome.hydratedFromBackend,
      resultingState: _stateMachine.current,
    );
  }

  bool _shouldPreserveOpenIncidentWithoutBackendPayload() {
    return _activeIncident != null && _isOpenSosState(_stateMachine.current);
  }

  bool _isOpenSosState(SosState state) {
    return switch (state) {
      SosState.arming ||
      SosState.triggerRequested ||
      SosState.triggeredLocal ||
      SosState.sending ||
      SosState.sent ||
      SosState.acknowledged ||
      SosState.cancelRequested =>
        true,
      SosState.idle ||
      SosState.cancelled ||
      SosState.resolved ||
      SosState.failed =>
        false,
    };
  }

  String _compactSummary(Object? value) {
    final summary = value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (summary.isEmpty) {
      return 'none';
    }
    return summary.length <= 240 ? summary : '${summary.substring(0, 240)}...';
  }

  void _emit(SosState state) {
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
    if (_localStore == null) return;

    await _localStore.saveString(
        SharedPrefsSdkStore.sosStateKey, _stateMachine.current.name);
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
