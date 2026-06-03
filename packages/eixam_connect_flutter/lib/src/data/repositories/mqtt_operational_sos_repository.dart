import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../../device/ble_debug_registry.dart';
import '../../mappers/local_state_serializers.dart';
import '../../mappers/sos_incident_mapper.dart';
import '../../sdk/operational_realtime_client.dart';
import '../../sdk/sdk_mqtt_contract.dart';
import '../../sdk/sos_backend_identity_normalizer.dart';
import '../../sdk/sos_origin_classifier.dart';
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
  String? _locallyClosedIncidentId;
  final Map<String, DateTime> _externalRelaySosPublishDedupe =
      <String, DateTime>{};

  Future<void> restoreState() async {
    if (_localStore == null) {
      return;
    }

    final incidentJson =
        await _localStore.readJson(SharedPrefsSdkStore.sosIncidentKey);
    final stateRaw =
        await _localStore.readString(SharedPrefsSdkStore.sosStateKey);
    _locallyClosedIncidentId =
        await _localStore.readString(SharedPrefsSdkStore.sosClosedIncidentKey);

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
    String? hardwareId,
    int? originatorNodeId,
    int? relayNodeId,
    String? relayDeviceId,
    String? relayHardwareId,
    String? relaySource,
    String? incidentId,
    String? cycleKey,
    OsSosWidgetActivation? osWidgetActivation,
    SdkDeviceBatterySnapshot? deviceBattery,
    SdkCoverageSnapshot? deviceCoverage,
    int? mobileBattery,
    SdkCoverageSnapshot? mobileCoverage,
  }) async {
    final originDecision = classifySosOrigin(
      source: relaySource,
      triggerSource: triggerSource,
      relaySource: relaySource,
      owner: originatorNodeId == null ? 'app' : 'device',
      originatorNodeId: originatorNodeId,
      relayNodeId: relayNodeId,
      deviceId: deviceId,
      hardwareId: hardwareId,
      forBackendPublish: true,
    );
    final current = _stateMachine.current;
    if (!originDecision.isExternalOnly &&
        current != SosState.idle &&
        current != SosState.failed &&
        current != SosState.cancelled &&
        current != SosState.resolved) {
      throw const SosException(
        'E_SOS_ALREADY_ACTIVE',
        'E_SOS_ALREADY_ACTIVE',
      );
    }
    final appOwnedSos = _isAppOwnedTriggerSource(triggerSource) ||
        (originatorNodeId == null && relayNodeId == null);
    BleDebugRegistry.instance.recordEvent(
      'SOS_TRANSPORT_DECISION flow=sos_trigger transport=mqtt '
      'source=$triggerSource reason=trigger_must_use_mqtt',
    );
    if (originDecision.isExternalOnly) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_ORIGIN_DECISION source=mqtt_repository_trigger '
        'actionability=${originDecision.actionability.name} '
        'localStateMutation=${originDecision.localStateMutation} '
        'publicIncident=${originDecision.publicIncident} '
        'backendPublish=${originDecision.backendPublish} '
        'reason=external_backend_publish_only:${originDecision.reason}',
      );
      await submitSosToBackend(
        timestamp: DateTime.now().toUtc(),
        positionSnapshot: positionSnapshot,
        deviceId: deviceId,
        hardwareId: hardwareId,
        originatorNodeId: originatorNodeId,
        relayNodeId: relayNodeId,
        relayDeviceId: relayDeviceId,
        relayHardwareId: relayHardwareId,
        relaySource: relaySource ?? triggerSource,
        incidentId: incidentId,
        cycleKey: cycleKey,
        osWidgetActivation: osWidgetActivation,
        deviceBattery: deviceBattery,
        deviceCoverage: deviceCoverage,
        mobileBattery: mobileBattery,
        mobileCoverage: mobileCoverage,
      );
      _activeIncident = null;
      _setState(SosState.idle);
      await _persistState();
      return SosIncident(
        id: incidentId ??
            'external-sos-${DateTime.now().microsecondsSinceEpoch}',
        state: SosState.idle,
        createdAt: DateTime.now().toUtc(),
        source: relaySource ?? triggerSource,
        triggerSource: triggerSource,
        relaySource: relaySource,
        originatorNodeId: originatorNodeId,
        relayNodeId: relayNodeId,
        deviceId: deviceId,
        hardwareId: hardwareId,
        owner: originatorNodeId == null ? 'app' : 'device',
        cycleKey: cycleKey,
        message: message,
        positionSnapshot: positionSnapshot,
      );
    }
    if (positionSnapshot == null && !appOwnedSos) {
      throw const SosException(
        'E_SOS_POSITION_REQUIRED',
        'E_SOS_POSITION_REQUIRED',
      );
    }

    _emit(SosState.triggerRequested);
    _emit(SosState.triggeredLocal);
    _emit(SosState.sending);

    try {
      final incident = await _triggerSosOverMqtt(
        message: message,
        triggerSource: triggerSource,
        positionSnapshot: positionSnapshot,
        deviceId: deviceId,
        hardwareId: hardwareId,
        originatorNodeId: originatorNodeId,
        relayNodeId: relayNodeId,
        relayDeviceId: relayDeviceId,
        relayHardwareId: relayHardwareId,
        relaySource: relaySource,
        incidentId: incidentId,
        cycleKey: cycleKey,
        osWidgetActivation: osWidgetActivation,
        deviceBattery: deviceBattery,
        deviceCoverage: deviceCoverage,
        mobileBattery: mobileBattery,
        mobileCoverage: mobileCoverage,
      );
      _activeIncident = incident;
      _locallyClosedIncidentId = null;
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

  bool _isAppOwnedTriggerSource(String triggerSource) {
    switch (triggerSource) {
      case 'button_ui':
      case 'commercial_app':
      case SosTriggerPayload.osWidgetSource:
        return true;
      default:
        return false;
    }
  }

  Future<SosIncident> _triggerSosOverMqtt({
    String? message,
    required String triggerSource,
    required TrackingPosition? positionSnapshot,
    String? deviceId,
    String? hardwareId,
    int? originatorNodeId,
    int? relayNodeId,
    String? relayDeviceId,
    String? relayHardwareId,
    String? relaySource,
    String? incidentId,
    String? cycleKey,
    OsSosWidgetActivation? osWidgetActivation,
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
      hardwareId: hardwareId,
      originatorNodeId: originatorNodeId,
      relayNodeId: relayNodeId,
      relayDeviceId: relayDeviceId,
      relayHardwareId: relayHardwareId,
      relaySource: relaySource,
      triggerSource: triggerSource,
      message: message,
      incidentId: incidentId ?? incident.id,
      cycleKey: cycleKey,
      osWidgetActivation: osWidgetActivation,
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
    String? hardwareId,
    int? originatorNodeId,
    int? relayNodeId,
    String? relayDeviceId,
    String? relayHardwareId,
    String? relaySource,
    String? triggerSource,
    String? message,
    String? incidentId,
    String? cycleKey,
    OsSosWidgetActivation? osWidgetActivation,
    SdkDeviceBatterySnapshot? deviceBattery,
    SdkCoverageSnapshot? deviceCoverage,
    int? mobileBattery,
    SdkCoverageSnapshot? mobileCoverage,
  }) async {
    final identity = normalizeSosBackendIdentity(
      deviceId: deviceId,
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
    final externalDecision = classifySosOrigin(
      source: relaySource,
      triggerSource: relaySource,
      relaySource: relaySource,
      owner: identity.originatorNodeId == null ? 'app' : 'device',
      originatorNodeId: identity.originatorNodeId,
      relayNodeId: relayNodeId,
      deviceId: identity.deviceId,
      hardwareId: identity.hardwareId,
      forBackendPublish: true,
    );
    final ownerLabel = externalDecision.isExternalOnly
        ? (identity.originatorNodeId == null ? 'external' : 'device')
        : (identity.originatorNodeId == null ? 'app' : 'device');
    final sourceLabel = _sourceLabel(
      relaySource: relaySource,
      triggerSource: triggerSource,
    );
    final correlationId = _nextCorrelationId('sos-mqtt');
    BleDebugRegistry.instance.recordEvent(
      'SOS_TRANSPORT_DECISION flow=sos_trigger transport=mqtt '
      'source=$sourceLabel reason=operational_sos_publish',
    );
    BleDebugRegistry.instance.recordEvent(
      'SOS_BACKEND_PAYLOAD_FINAL source=mqtt '
      'owner=$ownerLabel '
      'triggerSource=$sourceLabel '
      'deviceId=${identity.deviceId ?? "none"} '
      'nodeId=${identity.nodeId?.toString() ?? "none"} '
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
      hardwareId: identity.hardwareId,
      identitySource: identity.identitySource,
      originatorNodeId: identity.originatorNodeId,
      relayNodeId: relayNodeId,
      relayDeviceId: identity.relayDeviceId,
      relayHardwareId: relayHardwareId,
      source: relaySource,
      triggerSource: triggerSource ?? relaySource,
      relaySource: relaySource,
      owner: ownerLabel,
      message: message,
      incidentId: incidentId,
      cycleKey: cycleKey,
      osWidgetActivation: osWidgetActivation,
      deviceBattery: deviceBattery,
      deviceCoverage: deviceCoverage,
      mobileBattery: mobileBattery,
      mobileCoverage: mobileCoverage,
    );
    if (externalDecision.isExternalOnly) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_ORIGIN_DECISION source=mqtt_submit_sos '
        'actionability=${externalDecision.actionability.name} '
        'localStateMutation=false publicIncident=false backendPublish=true '
        'reason=remote_lora_relay_bypassed_background_sos',
      );
      if (_shouldSkipExternalRelaySosPublish(
        originatorNodeId: identity.originatorNodeId,
        relayNodeId: relayNodeId,
        relayHardwareId: relayHardwareId,
        incidentId: incidentId,
        cycleKey: cycleKey,
      )) {
        return;
      }
      try {
        BleDebugRegistry.instance.recordEvent(
          'SOS_TRIGGER_MQTT_PUBLISH_START source=$sourceLabel '
          'incidentId=${incidentId ?? "none"} correlationId=$correlationId '
          'cycleKey=${cycleKey ?? "none"}',
        );
        await _publishExternalSosToBackend(
          request: request,
          originatorNodeId: identity.originatorNodeId,
          relayNodeId: relayNodeId,
          relayHardwareId: relayHardwareId,
        );
        BleDebugRegistry.instance.recordEvent(
          'SOS_TRIGGER_MQTT_PUBLISH_RESULT source=$sourceLabel success=true',
        );
      } catch (_) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_TRIGGER_MQTT_PUBLISH_RESULT source=$sourceLabel success=false',
        );
        rethrow;
      }
      return;
    }
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
      'nodeId=${identity.nodeId?.toString() ?? "none"} '
      'hardwareId=${identity.hardwareId ?? "none"} '
      'userId=delegated_to_mqtt_client '
      'hasLocation=${positionSnapshot != null}',
    );
    final publishStopwatch = Stopwatch()..start();
    try {
      BleDebugRegistry.instance.recordEvent(
        'SOS_TRIGGER_MQTT_PUBLISH_START source=$sourceLabel '
        'incidentId=${incidentId ?? "none"} correlationId=$correlationId '
        'cycleKey=${cycleKey ?? "none"}',
      );
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] backend_publish_call_start state=sent '
        'incidentId=${incidentId ?? "none"} '
        'deviceId=${identity.deviceId ?? "none"} '
        'nodeId=${identity.nodeId?.toString() ?? "none"} '
        'hardwareId=${identity.hardwareId ?? "none"} '
        'identitySource=${identity.identitySource}',
      );
      await realtimeClient.publishOperationalSos(request);
      BleDebugRegistry.instance.recordEvent(
        'SOS_TRIGGER_MQTT_PUBLISH_RESULT source=$sourceLabel success=true',
      );
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
        'hardwareId=${identity.hardwareId ?? "none"} '
        'identitySource=${identity.identitySource}',
      );
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_TRIGGER_MQTT_PUBLISH_RESULT source=$sourceLabel success=false',
      );
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

  bool _shouldSkipExternalRelaySosPublish({
    required int? originatorNodeId,
    required int? relayNodeId,
    required String? relayHardwareId,
    required String? incidentId,
    required String? cycleKey,
  }) {
    final now = DateTime.now().toUtc();
    _externalRelaySosPublishDedupe.removeWhere(
      (_, seenAt) => now.difference(seenAt) > const Duration(seconds: 30),
    );
    final key = <String>[
      'remote_lora_relay',
      originatorNodeId?.toString() ?? 'none',
      relayNodeId?.toString() ?? 'none',
      relayHardwareId?.trim() ?? 'none',
      incidentId?.trim() ?? cycleKey?.trim() ?? 'active',
    ].join(':');
    if (_externalRelaySosPublishDedupe.containsKey(key)) {
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS dedupe_skip triggerSource=remote_lora_relay '
        'originatorNodeId=${originatorNodeId?.toString() ?? "none"} '
        'relayNodeId=${relayNodeId?.toString() ?? "none"} '
        'relayHardwareId=${relayHardwareId ?? "none"}',
      );
      return true;
    }
    _externalRelaySosPublishDedupe[key] = now;
    return false;
  }

  Future<void> _publishExternalSosToBackend({
    required MqttOperationalSosRequest request,
    required int? originatorNodeId,
    required int? relayNodeId,
    required String? relayHardwareId,
  }) async {
    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS backend_publish_start triggerSource=remote_lora_relay '
      'originatorNodeId=${originatorNodeId?.toString() ?? "none"} '
      'relayNodeId=${relayNodeId?.toString() ?? "none"} '
      'relayHardwareId=${relayHardwareId ?? "none"}',
    );
    await realtimeClient.publishOperationalSos(request);
    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS backend_publish_result result=publish_returned '
      'triggerSource=remote_lora_relay '
      'originatorNodeId=${originatorNodeId?.toString() ?? "none"} '
      'relayNodeId=${relayNodeId?.toString() ?? "none"}',
    );
  }

  @override
  Future<SosIncident> cancelSos() async {
    if (!await _ensureActiveIncidentForCancellation()) {
      throw const SosException(
        'E_SOS_CANCEL_NOT_ALLOWED',
        'E_SOS_CANCEL_NOT_ALLOWED',
      );
    }

    final remoteDataSource = cancelRemoteDataSource;
    if (remoteDataSource == null) {
      throw const SosException(
        'E_SOS_CANCEL_HTTP_UNAVAILABLE',
        'E_SOS_CANCEL_HTTP_UNAVAILABLE',
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
        'E_SOS_RESOLVE_NOT_ALLOWED',
      );
    }

    final remoteDataSource = cancelRemoteDataSource;
    if (remoteDataSource == null) {
      throw const SosException(
        'E_SOS_RESOLVE_HTTP_UNAVAILABLE',
        'E_SOS_RESOLVE_HTTP_UNAVAILABLE',
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
    required SosIncidentDto? cancelledDto,
  }) async {
    final cancelledIncident = cancelledDto == null
        ? _activeIncident!.copyWith(state: SosState.cancelled)
        : _mapper.toDomain(cancelledDto).copyWith(state: SosState.cancelled);
    _clearCurrentIncidentAfterCancellation(cancelledIncident);
    return cancelledIncident;
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

  void _clearCurrentIncidentAfterCancellation(SosIncident cancelledIncident) {
    _activeIncident = cancelledIncident;
    _locallyClosedIncidentId = cancelledIncident.id;
    _setState(SosState.cancelled);
    _activeIncident = null;
    _setState(SosState.idle);
  }

  bool _shouldIgnoreLocallyClosedIncident(SosIncident incident) {
    final closedIncidentId = _locallyClosedIncidentId;
    return closedIncidentId != null && incident.id == closedIncidentId;
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
            triggerSource: incident.triggerSource ??
                incident.source ??
                incident.relaySource,
            message: incident.message,
            deliveryChannel: incident.deliveryChannel,
            actuators: incident.actuators,
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
            diagnosticNote: 'E_SOS_REHYDRATION_KEPT_LOCAL_FALLBACK',
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

      final hydratedIncident = _mapper.toDomain(active);
      final originDecision = classifySosIncidentOrigin(hydratedIncident);
      if (originDecision.isExternalOnly) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_ORIGIN_DECISION source=mqtt_repository_rehydrate '
          'actionability=${originDecision.actionability.name} '
          'localStateMutation=${originDecision.localStateMutation} '
          'publicIncident=${originDecision.publicIncident} '
          'backendPublish=${originDecision.backendPublish} '
          'reason=external_backend_rehydration_blocked:${originDecision.reason}',
        );
        _activeIncident = null;
        _setState(SosState.idle);
        await _persistState();
        return const SosRuntimeRehydrationResult(
          outcome: SosRuntimeRehydrationOutcome.clearedToIdle,
          resultingState: SosState.idle,
          diagnosticNote: 'E_SOS_REHYDRATION_EXTERNAL_ONLY_IGNORED',
        );
      }
      if (_shouldIgnoreLocallyClosedIncident(hydratedIncident)) {
        _activeIncident = null;
        _setState(SosState.idle);
        await _persistState();
        return const SosRuntimeRehydrationResult(
          outcome: SosRuntimeRehydrationOutcome.clearedToIdle,
          resultingState: SosState.idle,
          diagnosticNote: 'E_SOS_REHYDRATION_IGNORED_LOCALLY_CLOSED_INCIDENT',
        );
      }
      if (_locallyClosedIncidentId != null &&
          hydratedIncident.id != _locallyClosedIncidentId) {
        _locallyClosedIncidentId = null;
      }

      _activeIncident = hydratedIncident;
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
        diagnosticNote: 'E_SOS_REHYDRATION_FAILED error=$error',
      );
    }
  }

  Future<void> dispose() async {
    await _realtimeSub?.cancel();
    await _stateController.close();
  }

  void _handleRealtimeEvent(RealtimeEvent event) {
    final update = MqttSosLifecycleUpdate.fromRealtimeEvent(event);
    if (update == null) {
      if (_isActuatorUpdateEvent(event)) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_ACTUATOR_UPDATE_IGNORED reason=missing_snapshot '
          'incidentId=${_eventIncidentId(event) ?? "none"} version=none',
        );
      }
      return;
    }
    final actuators = update.actuators;
    if (actuators != null) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_ACTUATOR_UPDATE_RECEIVED incidentId=${update.incidentId} '
        'version=${actuators.snapshotVersion} '
        'items=${_actuatorItemsSummary(actuators)}',
      );
    }
    if (_activeIncident == null) {
      if (actuators != null) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_ACTUATOR_UPDATE_IGNORED reason=incident_mismatch '
          'incidentId=${update.incidentId} activeIncidentId=none '
          'version=${actuators.snapshotVersion}',
        );
      }
      return;
    }
    if (update.incidentId != _activeIncident!.id) {
      if (actuators != null) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_ACTUATOR_UPDATE_IGNORED reason=incident_mismatch '
          'incidentId=${update.incidentId} '
          'activeIncidentId=${_activeIncident!.id} '
          'version=${actuators.snapshotVersion}',
        );
      }
      return;
    }
    if (!_isActiveLikeState(_stateMachine.current)) {
      if (actuators != null) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_ACTUATOR_UPDATE_IGNORED reason=stale '
          'incidentId=${update.incidentId} '
          'currentState=${_stateMachine.current.name} '
          'version=${actuators.snapshotVersion}',
        );
      }
      return;
    }

    final previousIncident = _activeIncident!;
    var currentIncident = previousIncident;
    var shouldPersist = false;

    if (actuators != null) {
      if (!_shouldAcceptActuatorSnapshot(
        current: currentIncident.actuators,
        incoming: actuators,
      )) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_ACTUATOR_UPDATE_IGNORED reason=stale '
          'incidentId=${update.incidentId} '
          'incomingVersion=${actuators.snapshotVersion} '
          'currentVersion=${currentIncident.actuators?.snapshotVersion ?? -1}',
        );
      } else {
        currentIncident = currentIncident.copyWith(actuators: actuators);
        _activeIncident = currentIncident;
        shouldPersist = true;
        BleDebugRegistry.instance.recordEvent(
          'SOS_ACTUATOR_UPDATE_ACCEPTED incidentId=${update.incidentId} '
          'version=${actuators.snapshotVersion}',
        );
      }
    }

    final state = update.state;
    if (state == null) {
      if (shouldPersist) {
        unawaited(_persistState());
        _emitActuatorOnlyUpdate(
          incidentId: update.incidentId,
          version: actuators?.snapshotVersion,
        );
      }
      return;
    }

    final nextIncident = currentIncident.copyWith(state: state);
    final accepted = _emit(
      state,
      previousIncident: currentIncident,
      incomingIncident: nextIncident,
      reason: 'realtime_event',
    );
    if (!accepted) {
      if (shouldPersist) {
        unawaited(_persistState());
        _emitActuatorOnlyUpdate(
          incidentId: update.incidentId,
          version: actuators?.snapshotVersion,
        );
      }
      return;
    }
    _activeIncident = nextIncident;
    _rememberActiveLikeStateIfNeeded(state);
    unawaited(_persistState());
  }

  bool _shouldAcceptActuatorSnapshot({
    required SosActuatorSnapshot? current,
    required SosActuatorSnapshot incoming,
  }) {
    return incoming.snapshotVersion > (current?.snapshotVersion ?? -1);
  }

  void _emitActuatorOnlyUpdate({
    required String incidentId,
    required int? version,
  }) {
    _stateController.add(_stateMachine.current);
    BleDebugRegistry.instance.recordEvent(
      'SOS_ACTUATOR_UPDATE_EMITTED incidentId=$incidentId '
      'version=${version?.toString() ?? "none"}',
    );
  }

  bool _isActuatorUpdateEvent(RealtimeEvent event) {
    return event.type.trim().toLowerCase() == 'sos.actuator_update' ||
        (event.payload?['type']?.toString().trim().toLowerCase() ==
            'sos.actuator_update');
  }

  String? _eventIncidentId(RealtimeEvent event) {
    final payload = event.payload;
    if (payload == null) {
      return null;
    }
    final direct = payload['incidentId'] ?? payload['id'];
    if (direct is String && direct.trim().isNotEmpty) {
      return direct.trim();
    }
    final incident = payload['incident'];
    if (incident is Map) {
      final nested = incident['id'];
      if (nested is String && nested.trim().isNotEmpty) {
        return nested.trim();
      }
    }
    return null;
  }

  String _actuatorItemsSummary(SosActuatorSnapshot snapshot) {
    if (snapshot.items.isEmpty) {
      return 'none';
    }
    return snapshot.items.map((item) {
      final type =
          item.rawType.trim().isNotEmpty ? item.rawType.trim() : item.type.name;
      final status = item.rawStatus.trim().isNotEmpty
          ? item.rawStatus.trim()
          : item.status.name;
      final outcome = item.rawOutcome.trim().isNotEmpty
          ? item.rawOutcome.trim()
          : item.outcome.name;
      return '$type:$status:$outcome';
    }).join(',');
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
    final closedIncidentId = _locallyClosedIncidentId;
    if (closedIncidentId == null || closedIncidentId.isEmpty) {
      await _localStore.remove(SharedPrefsSdkStore.sosClosedIncidentKey);
    } else {
      await _localStore.saveString(
        SharedPrefsSdkStore.sosClosedIncidentKey,
        closedIncidentId,
      );
    }
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

  String _errorMessageFor(Object error) {
    if (error is EixamSdkException) {
      return error.message;
    }
    return error.toString();
  }

  String _sourceLabel({
    required String? relaySource,
    required String? triggerSource,
  }) {
    final source = relaySource?.trim();
    if (source != null && source.isNotEmpty) {
      return source;
    }
    final trigger = triggerSource?.trim();
    if (trigger != null && trigger.isNotEmpty) {
      return trigger;
    }
    return 'mqtt_operational_sos';
  }

  String _nextCorrelationId(String prefix) =>
      '$prefix-${DateTime.now().toUtc().microsecondsSinceEpoch}';

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
