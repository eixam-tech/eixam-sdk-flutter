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
        _localStore = localStore {
    _stateController.add(_stateMachine.current);
    _realtimeSub = realtimeClient.watchEvents().listen(_handleRealtimeEvent);
  }

  final OperationalRealtimeClient realtimeClient;
  final SosRemoteDataSource? remoteDataSource;
  final SosRemoteDataSource? cancelRemoteDataSource;
  final SharedPrefsSdkStore? _localStore;
  final SosIncidentMapper _mapper = const SosIncidentMapper();
  SosStateMachine _stateMachine = SosStateMachine();
  final StreamController<SosState> _stateController =
      StreamController<SosState>.broadcast();

  StreamSubscription<RealtimeEvent>? _realtimeSub;
  SosIncident? _activeIncident;

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
    final appOwnedSos = originatorNodeId == null && relayNodeId == null;
    if (positionSnapshot == null && !appOwnedSos) {
      throw const SosException(
        'E_SOS_POSITION_REQUIRED',
        'Operational SOS over MQTT requires a current location snapshot.',
      );
    }

    _emit(SosState.triggerRequested);
    _emit(SosState.triggeredLocal);
    _emit(SosState.sending);

    try {
      final incident = appOwnedSos
          ? await _triggerAppOwnedSosOverHttp(
              message: message,
              triggerSource: triggerSource,
              positionSnapshot: positionSnapshot,
              deviceId: deviceId,
              appDeviceId: appDeviceId,
              hardwareId: hardwareId,
              incidentId: incidentId,
              cycleKey: cycleKey,
              deviceBattery: deviceBattery,
              deviceCoverage: deviceCoverage,
              mobileBattery: mobileBattery,
              mobileCoverage: mobileCoverage,
            )
          : await _triggerDeviceOrRelaySosOverMqtt(
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

  Future<SosIncident> _triggerAppOwnedSosOverHttp({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
    String? deviceId,
    String? appDeviceId,
    String? hardwareId,
    String? incidentId,
    String? cycleKey,
    SdkDeviceBatterySnapshot? deviceBattery,
    SdkCoverageSnapshot? deviceCoverage,
    int? mobileBattery,
    SdkCoverageSnapshot? mobileCoverage,
  }) async {
    final dataSource = remoteDataSource;
    final identity = normalizeSosBackendIdentity(
      deviceId: deviceId ?? appDeviceId,
      appDeviceId: appDeviceId,
      originatorNodeId: null,
      relayNodeId: null,
      relayDeviceId: null,
      incidentId: incidentId,
      cycleKey: cycleKey,
      hardwareId: null,
    );
    if (dataSource == null) {
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] app_sos_backend_publish_blocked '
        'reason=http_sos_remote_data_source_unavailable '
        'deviceId=${identity.deviceId ?? "none"} nodeId=none '
        'appDeviceId=${identity.appDeviceId ?? "none"} '
        'hardwareId=none identitySource=${identity.identitySource}',
      );
      throw const SosException(
        'E_APP_SOS_BACKEND_UNAVAILABLE',
        'HTTP SOS backend transport is unavailable for app-originated SOS.',
      );
    }
    BleDebugRegistry.instance.recordEvent(
      '[BACKGROUND_SOS] app_sos_backend_publish_start owner=app '
      'deviceId=${identity.deviceId ?? "none"} nodeId=none '
      'appDeviceId=${identity.appDeviceId ?? "none"} '
      'hardwareId=none identitySource=${identity.identitySource} '
      'hasLocation=${positionSnapshot != null}',
    );
    BleDebugRegistry.instance.recordEvent(
      '[BACKGROUND_SOS] app_sos_backend_http_request endpoint=/v1/sdk/sos '
      'payloadSummary=${_compactSummary('timestamp=${positionSnapshot?.timestamp.toUtc().toIso8601String() ?? DateTime.now().toUtc().toIso8601String()} hasLocation=${positionSnapshot != null} appDeviceId=${identity.appDeviceId ?? "none"} identitySource=${identity.identitySource} deviceId=${identity.deviceId ?? identity.appDeviceId ?? "none"} owner=app runtimeDeviceId=${deviceId ?? "none"} runtimeHardwareId=${hardwareId ?? "none"}')}',
    );
    try {
      final dto = await dataSource.triggerSos(
        message: message,
        triggerSource: triggerSource,
        positionSnapshot: positionSnapshot,
        deviceId: identity.deviceId ?? identity.appDeviceId,
        appDeviceId: identity.appDeviceId,
        hardwareId: null,
        incidentId: incidentId,
        cycleKey: cycleKey,
        deviceBattery: deviceBattery,
        deviceCoverage: deviceCoverage,
        mobileBattery: mobileBattery,
        mobileCoverage: mobileCoverage,
      );
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] app_sos_backend_publish_succeeded '
        'backendIncidentId=${dto.id} '
        'httpStatus=${dto.statusCode?.toString() ?? "none"}',
      );
      return _mapper.toDomain(dto);
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] app_sos_backend_publish_failed '
        'errorType=${error.runtimeType} '
        'httpStatus=${_httpStatusForError(error)} '
        'responseBody=${_responseBodyForError(error)} '
        'message=${_compactSummary(_errorMessageFor(error))}',
      );
      rethrow;
    }
  }

  Future<SosIncident> _triggerDeviceOrRelaySosOverMqtt({
    String? message,
    required String triggerSource,
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
  }) async {
    final incident = SosIncident(
      id: 'sos-${DateTime.now().microsecondsSinceEpoch}',
      state: SosState.sent,
      createdAt: DateTime.now().toUtc(),
      triggerSource: triggerSource,
      message: message,
      positionSnapshot: positionSnapshot,
    );
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
    BleDebugRegistry.instance.recordEvent(
      '[BACKGROUND_SOS] local_incident_created state=sent '
      'localIncidentId=${incident.id} backendIncidentId=none '
      'reason=mqtt_publish_accepted_without_backend_incident_payload',
    );
    return incident;
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
  }) async {
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
    if (_isLocalAppDeviceId(identity.deviceId)) {
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] backend_publish_warning '
        'reason=local_app_device_id_used_as_device_id '
        'state=sent transport=mqtt '
        'deviceId=${identity.deviceId ?? "none"} '
        'nodeId=${identity.nodeId?.toString() ?? "none"} '
        'appDeviceId=${identity.appDeviceId ?? "none"} '
        'hardwareId=${identity.hardwareId ?? "none"} '
        'identitySource=${identity.identitySource}',
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
    final request = MqttOperationalSosRequest(
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
    );
    BleDebugRegistry.instance.recordEvent(
      '[BACKGROUND_SOS] backend_publish_requested state=sent '
      'diagnostics_version=sos_backend_publish_trace_v3_actual_line '
      'before_requested=true occurrence=2',
    );
    BleDebugRegistry.instance.recordEvent(
      '[BACKGROUND_SOS] backend_publish_requested state=sent '
      'transport=mqtt topic=${SdkMqttTopics.sosAlerts} '
      'deviceId=${identity.deviceId ?? "none"} '
      'nodeId=${identity.nodeId?.toString() ?? "none"} '
      'appDeviceId=${identity.appDeviceId ?? "none"} '
      'hardwareId=${identity.hardwareId ?? "none"} '
      'identitySource=${identity.identitySource} '
      'incidentId=${incidentId ?? "none"}',
    );
    BleDebugRegistry.instance.recordEvent(
      '[BACKGROUND_SOS] backend_publish_requested state=sent '
      'diagnostics_version=sos_backend_publish_trace_v3_actual_line '
      'after_requested=true occurrence=2',
    );
    BleDebugRegistry.instance.recordEvent(
      '[BACKGROUND_SOS] diagnostics_version=sos_backend_publish_trace_v3_actual_line '
      'function=submitSosToBackend file=mqtt_operational_sos_repository.dart '
      'occurrence=2',
    );
    BleDebugRegistry.instance.recordEvent(
      '[BACKGROUND_SOS] diagnostics_version=sos_backend_publish_trace_v2',
    );
    BleDebugRegistry.instance.recordEvent(
      '[BACKGROUND_SOS] backend_publish_payload identity '
      'deviceId=${identity.deviceId ?? "none"} '
      'isLocalDeviceId=${_isLocalAppDeviceId(identity.deviceId)} '
      'nodeId=${identity.nodeId?.toString() ?? "none"} '
      'hardwareId=${identity.hardwareId ?? "none"} '
      'appDeviceId=${identity.appDeviceId ?? "none"} '
      'userId=delegated_to_mqtt_client '
      'hasLocation=${positionSnapshot != null}',
    );
    final publishStopwatch = Stopwatch()..start();
    try {
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] backend_publish_call_start state=sent '
        'incidentId=${incidentId ?? "none"} '
        'deviceId=${identity.deviceId ?? "none"} '
        'nodeId=${identity.nodeId?.toString() ?? "none"} '
        'hardwareId=${identity.hardwareId ?? "none"} '
        'appDeviceId=${identity.appDeviceId ?? "none"} '
        'identitySource=${identity.identitySource}',
      );
      await realtimeClient.publishOperationalSos(request);
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] backend_publish_call_returned state=sent '
        'resultType=void result=mqtt_publish_returned',
      );
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] backend_publish_succeeded state=sent '
        'transport=mqtt topic=${SdkMqttTopics.sosAlerts} '
        'backendIncidentId=none httpStatus=not_applicable '
        'mqttAck=publish_accepted '
        'backendConfirmation=not_available '
        'deviceId=${identity.deviceId ?? "none"} '
        'nodeId=${identity.nodeId?.toString() ?? "none"} '
        'appDeviceId=${identity.appDeviceId ?? "none"} '
        'hardwareId=${identity.hardwareId ?? "none"} '
        'identitySource=${identity.identitySource}',
      );
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] mqtt_publish_failed '
        'topic=${SdkMqttTopics.sosAlerts} reason=${_compactSummary(error)}',
      );
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] backend_publish_failed state=sent '
        'transport=mqtt errorType=${error.runtimeType} '
        'message=${_compactSummary(_errorMessageFor(error))} '
        'httpStatus=none responseBody=none '
        'endpoint=${SdkMqttTopics.sosAlerts} '
        'deviceId=${identity.deviceId ?? "none"} '
        'nodeId=${identity.nodeId?.toString() ?? "none"} '
        'appDeviceId=${identity.appDeviceId ?? "none"} '
        'hardwareId=${identity.hardwareId ?? "none"} '
        'identitySource=${identity.identitySource}',
      );
      rethrow;
    } finally {
      publishStopwatch.stop();
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] backend_publish_finally state=sent '
        'transport=mqtt elapsedMs=${publishStopwatch.elapsedMilliseconds}',
      );
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
    if (_isTerminalState(incomingState) ||
        incomingState == SosState.cancelRequested) {
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
    // A backend refresh with no active payload is not enough to erase an
    // open local incident; cancel/resolve need that id until a terminal
    // operation settles it explicitly.
    return true;
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

  void _rememberActiveLikeState() {}

  bool _isLocalAppDeviceId(String? value) {
    return value?.trim().startsWith('app-device-local-') == true;
  }

  String _errorMessageFor(Object error) {
    if (error is EixamSdkException) {
      return error.message;
    }
    return error.toString();
  }

  String _httpStatusForError(Object error) {
    return error is SosHttpException ? error.statusCode.toString() : 'none';
  }

  String _responseBodyForError(Object error) {
    return error is SosHttpException ? _compactSummary(error.message) : 'none';
  }

  String _compactSummary(Object? value) {
    final summary = value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (summary.isEmpty) {
      return 'none';
    }
    return summary.length <= 240 ? summary : '${summary.substring(0, 240)}...';
  }

  void _rememberActiveLikeStateIfNeeded(SosState state) {
    if (_isActiveLikeState(state)) {
      _rememberActiveLikeState();
    }
  }
}
