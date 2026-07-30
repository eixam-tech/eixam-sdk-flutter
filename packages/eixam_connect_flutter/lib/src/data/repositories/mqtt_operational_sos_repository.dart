import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

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
    implements
        SosRepository,
        SosRuntimeRehydrationSupport,
        MqttOnlyLiveSosLifecycle,
        SosRuntimeSessionIsolation,
        AuthoritativeActiveSosLookup {
  MqttOperationalSosRepository({
    required this.realtimeClient,
    SosRemoteDataSource? remoteDataSource,
    this.cancelRemoteDataSource,
    SharedPrefsSdkStore? localStore,
    this.preSosBackendPublishBlocker,
    Duration destructiveRehydrationGracePeriod = const Duration(seconds: 5),
    Duration mqttConfirmationWarningDelay = const Duration(seconds: 8),
    Duration actuatorBufferTtl = const Duration(seconds: 30),
    Duration processedHandoffWindow = const Duration(minutes: 2),
    Duration processedClockSkewTolerance = const Duration(seconds: 30),
    DateTime Function()? nowProvider,
  })  : remoteDataSource = remoteDataSource ?? cancelRemoteDataSource,
        _localStore = localStore,
        _destructiveRehydrationGracePeriod = destructiveRehydrationGracePeriod,
        _mqttConfirmationWarningDelay = mqttConfirmationWarningDelay,
        _actuatorBufferTtl = actuatorBufferTtl,
        _processedHandoffWindow = processedHandoffWindow,
        _processedClockSkewTolerance = processedClockSkewTolerance,
        _nowProvider = nowProvider ?? DateTime.now {
    _stateController.add(_stateMachine.current);
    _realtimeSub = realtimeClient.watchEvents().listen(_handleRealtimeEvent);
    BleDebugRegistry.instance.recordEvent(
      'SOS_MQTT_EVENT_REPOSITORY_LISTENER_ACTIVE parserReady=true',
    );
  }

  final OperationalRealtimeClient realtimeClient;
  final SosRemoteDataSource? remoteDataSource;
  final SosRemoteDataSource? cancelRemoteDataSource;
  final SharedPrefsSdkStore? _localStore;
  final Duration _destructiveRehydrationGracePeriod;
  final Duration _mqttConfirmationWarningDelay;
  final Duration _actuatorBufferTtl;
  final Duration _processedHandoffWindow;
  final Duration _processedClockSkewTolerance;
  final DateTime Function() _nowProvider;
  bool Function({
    required String source,
    required String? triggerSource,
    required String? cycleKey,
    required int? originatorNodeId,
    required int? packetId,
  })? preSosBackendPublishBlocker;
  final SosIncidentMapper _mapper = const SosIncidentMapper();
  SosStateMachine _stateMachine = SosStateMachine();
  final StreamController<SosState> _stateController =
      StreamController<SosState>.broadcast();

  StreamSubscription<RealtimeEvent>? _realtimeSub;
  SosIncident? _activeIncident;
  String? _locallyClosedIncidentId;
  final Map<String, String?> _trustedLifecycleCorrelationIds =
      <String, String?>{};
  final Map<String, DateTime> _externalRelaySosPublishDedupe =
      <String, DateTime>{};
  Timer? _mqttConfirmationWarningTimer;
  final Map<String, _BufferedActuatorUpdate> _bufferedActuatorUpdates =
      <String, _BufferedActuatorUpdate>{};
  final Map<String, DateTime> _handledMqttEvents = <String, DateTime>{};
  bool _disposed = false;

  @visibleForTesting
  String? get debugLastTrustedCorrelationId =>
      _trustedLifecycleCorrelationIds.isEmpty
          ? null
          : _trustedLifecycleCorrelationIds.keys.last;

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
      _activeIncident = LocalStateSerializers.sosIncidentFromJson(
        incidentJson,
      ).copyWith(isUsingCachedData: true);
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
      final staleGuardCleared = await _clearStaleAlreadyActiveGuardIfSafe(
        current: current,
        triggerSource: triggerSource,
        relaySource: relaySource,
        originatorNodeId: originatorNodeId,
        relayNodeId: relayNodeId,
        deviceId: deviceId,
        hardwareId: hardwareId,
      );
      if (staleGuardCleared) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_TRIGGER_CONTINUES_AFTER_STALE_GUARD_CLEAR '
          'stage=${_stateMachine.current.name} '
          'triggerSource=$triggerSource',
        );
      } else {
        throw const SosException(
          'E_SOS_ALREADY_ACTIVE',
          'E_SOS_ALREADY_ACTIVE',
        );
      }
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
      if (_stateMachine.current == SosState.idle) {
        _activeIncident = null;
      }
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
      _startMqttConfirmationWait(incident.id);
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

  Future<bool> _clearStaleAlreadyActiveGuardIfSafe({
    required SosState current,
    required String triggerSource,
    required String? relaySource,
    required int? originatorNodeId,
    required int? relayNodeId,
    required String? deviceId,
    required String? hardwareId,
  }) async {
    _logAlreadyActiveGuardDecision(
      'SOS_ALREADY_ACTIVE_GUARD_CHECK',
      stage: current,
      triggerSource: triggerSource,
      relaySource: relaySource,
      originatorNodeId: originatorNodeId,
      relayNodeId: relayNodeId,
      deviceId: deviceId,
      hardwareId: hardwareId,
      incident: _activeIncident,
      hasBackendActive: false,
      reason: 'open_local_state',
    );

    if (current == SosState.cancelRequested) {
      _logAlreadyActiveGuardDecision(
        'SOS_ALREADY_ACTIVE_GUARD_BLOCKED',
        stage: current,
        triggerSource: triggerSource,
        relaySource: relaySource,
        originatorNodeId: originatorNodeId,
        relayNodeId: relayNodeId,
        deviceId: deviceId,
        hardwareId: hardwareId,
        incident: _activeIncident,
        hasBackendActive: false,
        reason: 'cancel_pending',
      );
      return false;
    }

    if (_hasReliableOpenIncidentIdentity(_activeIncident)) {
      _logAlreadyActiveGuardDecision(
        'SOS_ALREADY_ACTIVE_GUARD_BLOCKED',
        stage: current,
        triggerSource: triggerSource,
        relaySource: relaySource,
        originatorNodeId: originatorNodeId,
        relayNodeId: relayNodeId,
        deviceId: deviceId,
        hardwareId: hardwareId,
        incident: _activeIncident,
        hasBackendActive: false,
        reason: 'active_incident_identity_present',
      );
      return false;
    }

    final rehydration = await rehydrateRuntimeStateFromBackend();
    final rehydratedState = _stateMachine.current;
    final rehydratedIncident = _activeIncident;
    final hasBackendActive = rehydration.outcome ==
            SosRuntimeRehydrationOutcome.hydratedFromBackend &&
        rehydratedIncident != null &&
        _isActiveLikeState(rehydratedState);
    if (hasBackendActive ||
        _hasReliableOpenIncidentIdentity(rehydratedIncident)) {
      _logAlreadyActiveGuardDecision(
        'SOS_ALREADY_ACTIVE_GUARD_BLOCKED',
        stage: rehydratedState,
        triggerSource: triggerSource,
        relaySource: relaySource,
        originatorNodeId: originatorNodeId,
        relayNodeId: relayNodeId,
        deviceId: deviceId,
        hardwareId: hardwareId,
        incident: rehydratedIncident,
        hasBackendActive: hasBackendActive,
        reason: hasBackendActive
            ? 'backend_active_rehydrated'
            : 'rehydrated_incident_identity_present',
      );
      return false;
    }

    if (_isActiveLikeState(rehydratedState)) {
      if (rehydration.outcome != SosRuntimeRehydrationOutcome.clearedToIdle) {
        _logAlreadyActiveGuardDecision(
          'SOS_ALREADY_ACTIVE_GUARD_BLOCKED',
          stage: rehydratedState,
          triggerSource: triggerSource,
          relaySource: relaySource,
          originatorNodeId: originatorNodeId,
          relayNodeId: relayNodeId,
          deviceId: deviceId,
          hardwareId: hardwareId,
          incident: rehydratedIncident,
          hasBackendActive: false,
          reason: 'rehydration_did_not_clear_open_state',
        );
        return false;
      }
      _activeIncident = null;
      _setState(SosState.idle);
      await _persistState();
    }

    _logAlreadyActiveGuardDecision(
      'SOS_ALREADY_ACTIVE_GUARD_STALE_CLEARED',
      stage: _stateMachine.current,
      triggerSource: triggerSource,
      relaySource: relaySource,
      originatorNodeId: originatorNodeId,
      relayNodeId: relayNodeId,
      deviceId: deviceId,
      hardwareId: hardwareId,
      incident: _activeIncident,
      hasBackendActive: false,
      reason: 'no_active_incident_after_rehydrate',
    );
    return true;
  }

  void _logAlreadyActiveGuardDecision(
    String event, {
    required SosState stage,
    required String triggerSource,
    required String? relaySource,
    required int? originatorNodeId,
    required int? relayNodeId,
    required String? deviceId,
    required String? hardwareId,
    required SosIncident? incident,
    required bool hasBackendActive,
    required String reason,
  }) {
    final incidentIdPresent = _normalizeIdentity(incident?.id) != null;
    final hasDeviceIdentity = originatorNodeId != null ||
        relayNodeId != null ||
        _normalizeIdentity(deviceId) != null ||
        _normalizeIdentity(hardwareId) != null ||
        incident?.originatorNodeId != null ||
        incident?.relayNodeId != null ||
        _normalizeIdentity(incident?.deviceId) != null ||
        _normalizeIdentity(incident?.hardwareId) != null;
    final owner = incident?.owner?.trim().isNotEmpty == true
        ? incident!.owner!.trim()
        : (originatorNodeId == null ? 'app' : 'device');
    BleDebugRegistry.instance.recordEvent(
      '$event '
      'stage=${stage.name} '
      'terminal=${_terminalLabel(stage)} '
      'incidentIdPresent=$incidentIdPresent '
      'source=${_sourceLabel(relaySource: relaySource, triggerSource: triggerSource)} '
      'owner=$owner '
      'triggerSource=$triggerSource '
      'hasDeviceIdentity=$hasDeviceIdentity '
      'hasBackendActive=$hasBackendActive '
      'reason=$reason',
    );
  }

  bool _hasReliableOpenIncidentIdentity(SosIncident? incident) {
    if (incident == null || !_isActiveLikeState(incident.state)) {
      return false;
    }
    return _normalizeIdentity(incident.id) != null ||
        _normalizeIdentity(incident.cycleKey) != null ||
        incident.originatorNodeId != null ||
        incident.relayNodeId != null ||
        _normalizeIdentity(incident.deviceId) != null ||
        _normalizeIdentity(incident.hardwareId) != null;
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
      cycleKey: cycleKey,
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
    if (preSosBackendPublishBlocker?.call(
          source: 'mqtt_operational_sos_repository.submitSosToBackend',
          triggerSource: sourceLabel,
          cycleKey: cycleKey,
          originatorNodeId: identity.originatorNodeId,
          packetId: null,
        ) ??
        false) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_PRE_SOS_BACKEND_PUBLISH_BLOCKED_BY_TERMINAL_CANCEL '
        'source=mqtt triggerSource=$sourceLabel '
        'cycleKey=${cycleKey ?? "none"} '
        'originatorNodeId=${identity.originatorNodeId?.toString() ?? "none"}',
      );
      return;
    }
    final correlationId = _nextCorrelationId('sos-mqtt');
    if (!externalDecision.isExternalOnly) {
      _trustedLifecycleCorrelationIds[correlationId] = _normalizeIdentity(
        incidentId,
      );
    }
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
    _clearPendingMqttLifecycle(reason: 'cancel_requested');
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
    _clearPendingMqttLifecycle(reason: 'resolve_requested');
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
    _emit(
      SosState.resolved,
      previousIncident: _activeIncident,
      incomingIncident: _activeIncident,
      reason: 'resolve_terminal_settle',
    );
    return _activeIncident!;
  }

  SosIncident _applyBackendIncident(SosIncidentDto dto) {
    final nextIncident = _mapper.toDomain(dto);
    final accepted = _emit(
      nextIncident.state,
      previousIncident: _activeIncident,
      incomingIncident: nextIncident,
      reason: 'backend_incident_settle',
    );
    if (!accepted && _stateMachine.current != nextIncident.state) {
      return _activeIncident ?? nextIncident;
    }
    _activeIncident = nextIncident;
    if (_isActiveLikeState(nextIncident.state)) {
      _rememberActiveLikeState();
    }
    return _activeIncident!;
  }

  void _clearCurrentIncidentAfterCancellation(SosIncident cancelledIncident) {
    _activeIncident = cancelledIncident;
    _locallyClosedIncidentId = cancelledIncident.id;
    _emit(
      SosState.cancelled,
      previousIncident: cancelledIncident,
      incomingIncident: cancelledIncident,
      reason: 'cancel_terminal_settle',
    );
    _activeIncident = null;
    _emit(
      SosState.idle,
      previousIncident: cancelledIncident,
      reason: 'cancel_terminal_settle',
    );
  }

  bool _shouldIgnoreLocallyClosedIncident(SosIncident incident) {
    final closedIncidentId = _locallyClosedIncidentId;
    return closedIncidentId != null && incident.id == closedIncidentId;
  }

  @override
  Future<SosIncident?> getCurrentIncident() async => _activeIncident;

  @override
  Future<SosState> getSosState() async => _stateMachine.current;

  @override
  Stream<SosState> watchSosState() => _stateController.stream;

  @override
  Stream<SosIncident?> watchCurrentIncident() async* {
    yield _activeIncident;
    await for (final _ in _stateController.stream) {
      yield _activeIncident;
    }
  }

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

  void _startMqttConfirmationWait(String localIncidentId) {
    _mqttConfirmationWarningTimer?.cancel();
    BleDebugRegistry.instance.recordEvent(
      'SOS_BACKEND_CONFIRMATION_WAIT_STARTED transport=mqtt',
    );
    _mqttConfirmationWarningTimer = Timer(_mqttConfirmationWarningDelay, () {
      final incident = _activeIncident;
      if (_disposed ||
          incident == null ||
          incident.id != localIncidentId ||
          incident.isBackendConfirmed ||
          !_isActiveLikeState(_stateMachine.current)) {
        return;
      }
      BleDebugRegistry.instance.recordEvent(
        'SOS_BACKEND_CONFIRMATION_TIMEOUT transport=mqtt '
        'state=confirming noRestFallback=true',
      );
    });
  }

  void _stopMqttConfirmationWait({required String reason}) {
    if (_mqttConfirmationWarningTimer != null) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_BACKEND_CONFIRMATION_WAIT_STOPPED transport=mqtt reason=$reason',
      );
    }
    _mqttConfirmationWarningTimer?.cancel();
    _mqttConfirmationWarningTimer = null;
  }

  void _clearPendingMqttLifecycle({required String reason}) {
    _stopMqttConfirmationWait(reason: reason);
    if (_bufferedActuatorUpdates.isNotEmpty) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_MQTT_ACTUATOR_UPDATE_BUFFER_CLEARED reason=$reason '
        'count=${_bufferedActuatorUpdates.length}',
      );
    }
    for (final buffered in _bufferedActuatorUpdates.values) {
      buffered.expiryTimer.cancel();
    }
    _bufferedActuatorUpdates.clear();
    _handledMqttEvents.clear();
  }

  void _logProgressSummary(SosIncident incident) {
    final contactStep = incident.progress.steps.where(
      (step) => step.type == SosProgressStepType.emergencyContacts,
    );
    final contacts = contactStep.isEmpty ? null : contactStep.first;
    BleDebugRegistry.instance.recordEvent(
      'SOS_PROGRESS_STREAM_EMIT backendConfirmed='
      '${incident.isBackendConfirmed} steps=${incident.progress.steps.length}',
    );
    if (incident.actuators != null) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_ACTUATOR_SNAPSHOT_RECEIVED version='
        '${incident.actuators!.snapshotVersion} '
        'items=${incident.actuators!.items.length}',
      );
    }
    if (contacts != null) {
      final total = contacts.totalTargets ?? 0;
      final delivered = contacts.successfulTargets ?? 0;
      final failed = contacts.failedTargets ?? 0;
      final inProgress = (total - delivered - failed).clamp(0, total);
      BleDebugRegistry.instance.recordEvent(
        'SOS_CONTACT_PROGRESS_NORMALIZED contactTargets=$total '
        'delivered=$delivered inProgress=$inProgress failed=$failed '
        'state=${contacts.state.name}',
      );
    }
  }

  @override
  Future<SosIncident?> getAuthoritativeActiveSos() async {
    final dataSource = remoteDataSource;
    if (dataSource == null) {
      return null;
    }
    final active = await dataSource.getActiveSos();
    return active == null ? null : _mapper.toDomain(active);
  }

  @override
  Future<void> clearSosRuntimeForSessionChange() async {
    _clearPendingMqttLifecycle(reason: 'session_cleared');
    _activeIncident = null;
    _locallyClosedIncidentId = null;
    _trustedLifecycleCorrelationIds.clear();
    _externalRelaySosPublishDedupe.clear();
    _setState(SosState.idle);
    await _persistState();
  }

  Future<void> dispose() async {
    _disposed = true;
    _clearPendingMqttLifecycle(reason: 'repository_disposed');
    await _realtimeSub?.cancel();
    await _stateController.close();
  }

  void _handleRealtimeEvent(RealtimeEvent event) {
    final update = MqttSosLifecycleUpdate.fromRealtimeEvent(event);
    if (update == null) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_MQTT_EVENT_PARSE_REJECTED '
        'reason=${_mqttParseRejectionReason(event)} '
        'eventType=${event.type.trim().isEmpty ? "unknown" : event.type}',
      );
      return;
    }
    if (_isDuplicateMqttEvent(update)) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_MQTT_EVENT_AUTHORITY_REJECTED reason=duplicate_alias_or_event '
        'eventType=${update.eventType}',
      );
      return;
    }
    final actuators = update.actuators;
    if (actuators != null && update.eventType == 'sos.actuator_update') {
      BleDebugRegistry.instance.recordEvent(
        'SOS_MQTT_ACTUATOR_UPDATE_RECEIVED '
        'version=${actuators.snapshotVersion} '
        'items=${_actuatorItemsSummary(actuators)}',
      );
    }
    if (_shouldBufferActuatorUpdate(update)) {
      _bufferActuatorUpdate(event, update);
      return;
    }
    final authority = _lifecycleAuthorityFor(update);
    if (!authority.accepted) {
      if (actuators != null) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_ACTUATOR_UPDATE_IGNORED reason=incident_mismatch '
          'incidentId=${update.incidentId} '
          'activeIncidentId=${_activeIncident?.id ?? "none"} '
          'version=${actuators.snapshotVersion}',
        );
      }
      return;
    }
    _rememberMqttEvent(update);
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
    final incidentIdentifierChanged = previousIncident.id != update.incidentId;
    if (incidentIdentifierChanged) {
      _activeIncident = _incidentWithId(
        previousIncident,
        update.incidentId,
        trustedCanonicalHandoff: !previousIncident.isBackendConfirmed &&
            previousIncident.id.startsWith('sos-'),
      );
    }
    var currentIncident = _activeIncident!;
    var shouldPersist = !currentIncident.isBackendConfirmed ||
        currentIncident.isUsingCachedData;
    currentIncident = currentIncident.copyWith(
      isBackendConfirmed: true,
      isUsingCachedData: false,
    );
    _activeIncident = currentIncident;
    if (!previousIncident.isBackendConfirmed) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_BACKEND_CONFIRMATION_MQTT_RECEIVED eventType=${update.eventType} '
        'actuatorItems=${actuators?.items.length ?? 0}',
      );
      if (update.eventType == 'processed') {
        BleDebugRegistry.instance.recordEvent(
          'SOS_MQTT_PROCESSED_ACCEPTED canonicalIncidentIdPresent=true',
        );
      }
      BleDebugRegistry.instance.recordEvent(
        'SOS_CANONICAL_INCIDENT_HANDOFF source=mqtt '
        'preservedLocalOwnership=true',
      );
      _stopMqttConfirmationWait(reason: 'mqtt_confirmation_received');
    }

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
        currentIncident = currentIncident.copyWith(
          actuators: actuators,
          isUsingCachedData: false,
        );
        _activeIncident = currentIncident;
        shouldPersist = true;
        BleDebugRegistry.instance.recordEvent(
          'SOS_ACTUATOR_UPDATE_ACCEPTED incidentId=${update.incidentId} '
          'version=${actuators.snapshotVersion}',
        );
        if (update.eventType == 'sos.actuator_update') {
          BleDebugRegistry.instance.recordEvent(
            'SOS_MQTT_ACTUATOR_UPDATE_APPLIED '
            'version=${actuators.snapshotVersion}',
          );
        }
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
        _logProgressSummary(currentIncident);
      }
      if (incidentIdentifierChanged) {
        _applyBufferedActuatorUpdate(update.incidentId);
      }
      return;
    }

    final nextIncident = currentIncident.copyWith(
      state: state,
      isUsingCachedData: false,
      terminalReason: _terminalReasonForUpdate(
        update: update,
        previousIncident: currentIncident,
        state: state,
      ),
    );
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
      if (incidentIdentifierChanged) {
        _applyBufferedActuatorUpdate(update.incidentId);
      }
      return;
    }
    _activeIncident = nextIncident;
    _rememberActiveLikeStateIfNeeded(state);
    unawaited(_persistState());
    _logProgressSummary(nextIncident);
    if (incidentIdentifierChanged) {
      _applyBufferedActuatorUpdate(update.incidentId);
    }
  }

  _LifecycleAuthorityDecision _lifecycleAuthorityFor(
    MqttSosLifecycleUpdate update,
  ) {
    final activeIncident = _activeIncident;
    final activeIncidentId = activeIncident?.id;
    if (_isExternalOnlyLifecycle(update)) {
      _logLifecycleAuthorityRejected(
        update: update,
        activeIncidentId: activeIncidentId,
        reason: 'external_only',
        diagnostic: 'MQTT_SOS_LIFECYCLE_REJECTED_EXTERNAL_ONLY',
      );
      return const _LifecycleAuthorityDecision.rejected('external_only');
    }

    if (activeIncident == null) {
      _logLifecycleAuthorityRejected(
        update: update,
        activeIncidentId: null,
        reason: 'missing_active_incident',
        diagnostic: 'MQTT_SOS_LIFECYCLE_REJECTED_IDENTITY_MISMATCH',
      );
      return const _LifecycleAuthorityDecision.rejected(
        'missing_active_incident',
      );
    }

    if (_sameIdentity(update.incidentId, activeIncident.id)) {
      _logLifecycleAuthorityAccepted(
        update: update,
        activeIncidentId: activeIncident.id,
        reason: 'active_incident_match',
        diagnostic: 'MQTT_SOS_LIFECYCLE_ACCEPTED_ACTIVE_INCIDENT_MATCH',
      );
      return const _LifecycleAuthorityDecision.accepted(
        'active_incident_match',
      );
    }

    if (_sameIdentity(update.clientIncidentId, activeIncident.id)) {
      _logLifecycleAuthorityAccepted(
        update: update,
        activeIncidentId: activeIncident.id,
        reason: 'client_incident_match',
        diagnostic: 'MQTT_SOS_LIFECYCLE_AUTHORITY_ACCEPTED',
      );
      return const _LifecycleAuthorityDecision.accepted(
        'client_incident_match',
      );
    }

    if (_hasTrustedCorrelationMatch(update, activeIncident)) {
      _logLifecycleAuthorityAccepted(
        update: update,
        activeIncidentId: activeIncident.id,
        reason: 'correlation_match',
        diagnostic: 'MQTT_SOS_LIFECYCLE_ACCEPTED_CORRELATION_MATCH',
      );
      return const _LifecycleAuthorityDecision.accepted('correlation_match');
    }

    if (_sameIdentity(update.cycleKey, activeIncident.cycleKey)) {
      _logLifecycleAuthorityAccepted(
        update: update,
        activeIncidentId: activeIncident.id,
        reason: 'cycle_match',
        diagnostic: 'MQTT_SOS_LIFECYCLE_ACCEPTED_CYCLE_MATCH',
      );
      return const _LifecycleAuthorityDecision.accepted('cycle_match');
    }

    // The production backend's processed event is published on an
    // authenticated, user-scoped topic, but intentionally contains only the
    // canonical incident id. It does not echo clientIncidentId/correlationId.
    // While exactly one freshly published local incident is awaiting backend
    // confirmation, that scoped processed event is the canonical handoff.
    if (update.eventType == 'processed' &&
        update.authenticatedUserScoped &&
        !activeIncident.isBackendConfirmed &&
        activeIncident.id.startsWith('sos-') &&
        _isProcessedTimestampCompatible(update, activeIncident) &&
        _isActiveLikeState(_stateMachine.current)) {
      _logLifecycleAuthorityAccepted(
        update: update,
        activeIncidentId: activeIncident.id,
        reason: 'user_scoped_processed_handoff',
        diagnostic: 'MQTT_SOS_LIFECYCLE_ACCEPTED_PROCESSED_HANDOFF',
      );
      return const _LifecycleAuthorityDecision.accepted(
        'user_scoped_processed_handoff',
      );
    }

    if (update.eventType == 'processed' && !update.authenticatedUserScoped) {
      _logLifecycleAuthorityRejected(
        update: update,
        activeIncidentId: activeIncident.id,
        reason: 'untrusted_topic',
        diagnostic: 'MQTT_SOS_LIFECYCLE_REJECTED_IDENTITY_MISMATCH',
      );
      return const _LifecycleAuthorityDecision.rejected('untrusted_topic');
    }

    if (update.eventType == 'processed' &&
        !_isProcessedTimestampCompatible(update, activeIncident)) {
      _logLifecycleAuthorityRejected(
        update: update,
        activeIncidentId: activeIncident.id,
        reason: 'publish_window_mismatch',
        diagnostic: 'MQTT_SOS_LIFECYCLE_REJECTED_IDENTITY_MISMATCH',
      );
      return const _LifecycleAuthorityDecision.rejected(
        'publish_window_mismatch',
      );
    }

    _logLifecycleAuthorityRejected(
      update: update,
      activeIncidentId: activeIncident.id,
      reason: 'identity_mismatch',
      diagnostic: 'MQTT_SOS_LIFECYCLE_REJECTED_IDENTITY_MISMATCH',
    );
    return const _LifecycleAuthorityDecision.rejected('identity_mismatch');
  }

  bool _hasTrustedCorrelationMatch(
    MqttSosLifecycleUpdate update,
    SosIncident activeIncident,
  ) {
    final correlationId = _normalizeIdentity(update.correlationId);
    if (correlationId == null) {
      return false;
    }
    if (!_trustedLifecycleCorrelationIds.containsKey(correlationId)) {
      return false;
    }
    final expectedIncidentId = _trustedLifecycleCorrelationIds[correlationId];
    return expectedIncidentId == null ||
        _sameIdentity(expectedIncidentId, activeIncident.id) ||
        _sameIdentity(expectedIncidentId, update.clientIncidentId);
  }

  bool _isExternalOnlyLifecycle(MqttSosLifecycleUpdate update) {
    if (_normalizeLifecycleToken(update.actionability) == 'externalonly' ||
        _normalizeLifecycleToken(update.displaySurface) == 'historyonly') {
      return true;
    }
    return classifySosOrigin(
      source: update.source,
      triggerSource: update.triggerSource,
      relaySource: update.relaySource,
      owner: update.owner,
    ).isExternalOnly;
  }

  void _logLifecycleAuthorityAccepted({
    required MqttSosLifecycleUpdate update,
    required String activeIncidentId,
    required String reason,
    required String diagnostic,
  }) {
    BleDebugRegistry.instance.recordEvent(
      'SOS_MQTT_EVENT_AUTHORITY_ACCEPTED reason=$reason '
      'eventType=${update.eventType} '
      'topicCategory=${update.topicCategory ?? "unknown"}',
    );
    BleDebugRegistry.instance.recordEvent(
      'MQTT_SOS_LIFECYCLE_AUTHORITY_ACCEPTED reason=$reason '
      'incidentId=${update.incidentId} activeIncidentId=$activeIncidentId '
      'clientIncidentId=${update.clientIncidentId ?? "none"} '
      'correlationId=${update.correlationId ?? "none"} '
      'cycleKey=${update.cycleKey ?? "none"}',
    );
    if (diagnostic != 'MQTT_SOS_LIFECYCLE_AUTHORITY_ACCEPTED') {
      BleDebugRegistry.instance.recordEvent(
        '$diagnostic incidentId=${update.incidentId} '
        'activeIncidentId=$activeIncidentId',
      );
    }
  }

  void _logLifecycleAuthorityRejected({
    required MqttSosLifecycleUpdate update,
    required String? activeIncidentId,
    required String reason,
    required String diagnostic,
  }) {
    BleDebugRegistry.instance.recordEvent(
      'SOS_MQTT_EVENT_AUTHORITY_REJECTED reason=$reason '
      'eventType=${update.eventType} '
      'topicCategory=${update.topicCategory ?? "unknown"}',
    );
    BleDebugRegistry.instance.recordEvent(
      'MQTT_SOS_LIFECYCLE_AUTHORITY_REJECTED reason=$reason '
      'incidentId=${update.incidentId} '
      'activeIncidentId=${activeIncidentId ?? "none"} '
      'clientIncidentId=${update.clientIncidentId ?? "none"} '
      'correlationId=${update.correlationId ?? "none"} '
      'cycleKey=${update.cycleKey ?? "none"} '
      'source=${update.source ?? "none"} '
      'triggerSource=${update.triggerSource ?? "none"} '
      'relaySource=${update.relaySource ?? "none"}',
    );
    BleDebugRegistry.instance.recordEvent(
      '$diagnostic reason=$reason incidentId=${update.incidentId} '
      'activeIncidentId=${activeIncidentId ?? "none"}',
    );
  }

  bool _isProcessedTimestampCompatible(
    MqttSosLifecycleUpdate update,
    SosIncident activeIncident,
  ) {
    final eventAt = update.eventTimestamp.toUtc();
    final createdAt = activeIncident.createdAt.toUtc();
    final earliest = createdAt.subtract(_processedClockSkewTolerance);
    final latest = createdAt.add(_processedHandoffWindow);
    final futureLimit =
        _nowProvider().toUtc().add(_processedClockSkewTolerance);
    return !eventAt.isBefore(earliest) &&
        !eventAt.isAfter(latest) &&
        !eventAt.isAfter(futureLimit);
  }

  bool _shouldBufferActuatorUpdate(MqttSosLifecycleUpdate update) {
    final active = _activeIncident;
    return update.eventType == 'sos.actuator_update' &&
        update.actuators != null &&
        update.authenticatedUserScoped &&
        active != null &&
        !active.isBackendConfirmed &&
        active.id.startsWith('sos-') &&
        !_sameIdentity(update.incidentId, active.id) &&
        _isActiveLikeState(_stateMachine.current) &&
        !_isExternalOnlyLifecycle(update) &&
        _isProcessedTimestampCompatible(update, active);
  }

  void _bufferActuatorUpdate(
    RealtimeEvent event,
    MqttSosLifecycleUpdate update,
  ) {
    final existing = _bufferedActuatorUpdates[update.incidentId];
    final incomingVersion = update.actuators!.snapshotVersion;
    if (existing != null &&
        existing.update.actuators!.snapshotVersion >= incomingVersion) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_MQTT_ACTUATOR_UPDATE_BUFFERED outcome=duplicate_ignored '
        'version=$incomingVersion',
      );
      return;
    }
    existing?.expiryTimer.cancel();
    late final Timer expiryTimer;
    expiryTimer = Timer(_actuatorBufferTtl, () {
      final buffered = _bufferedActuatorUpdates[update.incidentId];
      if (buffered == null || !identical(buffered.expiryTimer, expiryTimer)) {
        return;
      }
      _bufferedActuatorUpdates.remove(update.incidentId);
      BleDebugRegistry.instance.recordEvent(
        'SOS_MQTT_ACTUATOR_UPDATE_BUFFER_CLEARED reason=expired count=1',
      );
    });
    _bufferedActuatorUpdates[update.incidentId] = _BufferedActuatorUpdate(
      event: event,
      update: update,
      expiryTimer: expiryTimer,
    );
    BleDebugRegistry.instance.recordEvent(
      'SOS_MQTT_EVENT_AUTHORITY_ACCEPTED '
      'reason=buffered_for_pending_handoff '
      'eventType=${update.eventType} '
      'topicCategory=${update.topicCategory ?? "unknown"}',
    );
    BleDebugRegistry.instance.recordEvent(
      'SOS_MQTT_ACTUATOR_UPDATE_BUFFERED outcome=stored '
      'version=$incomingVersion',
    );
  }

  void _applyBufferedActuatorUpdate(String canonicalIncidentId) {
    final buffered = _bufferedActuatorUpdates.remove(canonicalIncidentId);
    if (buffered == null) {
      return;
    }
    buffered.expiryTimer.cancel();
    BleDebugRegistry.instance.recordEvent(
      'SOS_MQTT_ACTUATOR_UPDATE_APPLIED source=pre_processed_buffer '
      'version=${buffered.update.actuators!.snapshotVersion}',
    );
    _handleRealtimeEvent(buffered.event);
  }

  bool _isDuplicateMqttEvent(MqttSosLifecycleUpdate update) {
    final now = _nowProvider().toUtc();
    _handledMqttEvents.removeWhere(
      (_, handledAt) => now.difference(handledAt) > const Duration(minutes: 5),
    );
    return _handledMqttEvents.containsKey(_mqttEventDedupeKey(update));
  }

  void _rememberMqttEvent(MqttSosLifecycleUpdate update) {
    _handledMqttEvents[_mqttEventDedupeKey(update)] = _nowProvider().toUtc();
  }

  String _mqttEventDedupeKey(MqttSosLifecycleUpdate update) {
    final eventId = _normalizeIdentity(update.eventId);
    if (eventId != null) {
      return 'event:$eventId';
    }
    return '${update.eventType}|${update.incidentId}|'
        '${update.state?.name ?? "none"}|'
        '${update.terminalReason?.name ?? "none"}|'
        '${update.actuators?.snapshotVersion ?? -1}|'
        '${update.eventTimestamp.toUtc().toIso8601String()}';
  }

  String _mqttParseRejectionReason(RealtimeEvent event) {
    if (_eventIncidentId(event) == null) {
      return 'missing_incident_id';
    }
    if (_isActuatorUpdateEvent(event)) {
      return 'missing_actuator_snapshot';
    }
    return 'unsupported_event_type';
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
      final restartPath = _terminalRestartPath(
        from: previousState,
        to: incomingState,
        reason: reason,
      );
      if (restartPath != null) {
        for (final next in restartPath) {
          _stateMachine.transitionTo(next);
          _rememberActiveLikeStateIfNeeded(next);
          _stateController.add(_stateMachine.current);
        }
        _logTransitionGuard(
          decision: 'accepted_via_valid_path',
          previousState: previousState,
          incomingState: incomingState,
          previousIncident: previousIncident,
          incomingIncident: incomingIncident,
          reason: reason,
        );
        return true;
      }
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
      return _transitionLiveThroughKnownPath(
        previousState: previousState,
        incomingState: incomingState,
        previousIncident: previousIncident,
        incomingIncident: incomingIncident,
        reason: reason,
      );
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

  List<SosState>? _terminalRestartPath({
    required SosState from,
    required SosState to,
    required String reason,
  }) {
    if (reason == 'realtime_event' || !_isTerminalState(from)) {
      return null;
    }
    if (to == SosState.triggerRequested) {
      return const <SosState>[
        SosState.idle,
        SosState.triggerRequested,
      ];
    }
    return null;
  }

  bool _transitionLiveThroughKnownPath({
    required SosState previousState,
    required SosState incomingState,
    required SosIncident? previousIncident,
    required SosIncident? incomingIncident,
    required String reason,
  }) {
    final path = _liveTransitionPath(
      from: previousState,
      to: incomingState,
    );
    if (path == null) {
      _logTransitionGuard(
        decision: 'ignore_invalid_transition',
        previousState: previousState,
        incomingState: incomingState,
        previousIncident: previousIncident,
        incomingIncident: incomingIncident,
        reason: 'invalid_live_transition:$reason',
      );
      return false;
    }

    for (final next in path) {
      _stateMachine.transitionTo(next);
      _rememberActiveLikeStateIfNeeded(next);
      _stateController.add(_stateMachine.current);
    }
    _logTransitionGuard(
      decision: 'accepted_via_valid_path',
      previousState: previousState,
      incomingState: incomingState,
      previousIncident: previousIncident,
      incomingIncident: incomingIncident,
      reason: reason,
    );
    return true;
  }

  List<SosState>? _liveTransitionPath({
    required SosState from,
    required SosState to,
  }) {
    if (SosStateMachine.canTransition(from: from, to: to)) {
      return <SosState>[to];
    }
    if (from == SosState.sent && to == SosState.cancelled) {
      return const <SosState>[
        SosState.cancelRequested,
        SosState.cancelled,
      ];
    }
    return null;
  }

  SosTerminalReason? _terminalReasonForUpdate({
    required MqttSosLifecycleUpdate update,
    required SosIncident previousIncident,
    required SosState state,
  }) {
    if (!_isTerminalState(state) && state != SosState.failed) {
      return previousIncident.terminalReason;
    }
    return update.terminalReason ?? previousIncident.terminalReason;
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
    final incident = _activeIncident!;
    if (incident.isBackendConfirmed || incident.isUsingCachedData) {
      return false;
    }
    return _nowProvider().toUtc().difference(incident.createdAt.toUtc()) <
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

  void _rememberActiveLikeState() {}

  SosIncident _incidentWithId(
    SosIncident incident,
    String id, {
    bool trustedCanonicalHandoff = false,
  }) {
    return SosIncident(
      id: id,
      state: incident.state,
      createdAt: incident.createdAt,
      positionSnapshot: incident.positionSnapshot,
      source: incident.source,
      triggerSource: incident.triggerSource,
      relaySource: incident.relaySource,
      originatorNodeId: incident.originatorNodeId,
      relayNodeId: incident.relayNodeId,
      deviceId: incident.deviceId,
      hardwareId: incident.hardwareId,
      owner: incident.owner,
      cycleKey: incident.cycleKey,
      message: incident.message,
      deliveryChannel: incident.deliveryChannel,
      terminalReason: incident.terminalReason,
      originKind: incident.originKind,
      actionability: incident.actionability,
      displaySurface: incident.displaySurface,
      actuators: incident.actuators,
      isBackendConfirmed: incident.isBackendConfirmed,
      isUsingCachedData: incident.isUsingCachedData,
      provisionalIncidentId: trustedCanonicalHandoff
          ? incident.provisionalIncidentId ?? incident.id
          : incident.provisionalIncidentId,
      preservedLocalOwnership:
          trustedCanonicalHandoff || incident.preservedLocalOwnership,
    );
  }

  bool _sameIdentity(String? left, String? right) {
    final normalizedLeft = _normalizeIdentity(left);
    final normalizedRight = _normalizeIdentity(right);
    return normalizedLeft != null &&
        normalizedRight != null &&
        normalizedLeft == normalizedRight;
  }

  String? _normalizeIdentity(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }

  String? _normalizeLifecycleToken(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed.toLowerCase().replaceAll(RegExp(r'[-_\s]+'), '');
  }

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

class _BufferedActuatorUpdate {
  const _BufferedActuatorUpdate({
    required this.event,
    required this.update,
    required this.expiryTimer,
  });

  final RealtimeEvent event;
  final MqttSosLifecycleUpdate update;
  final Timer expiryTimer;
}

class _LifecycleAuthorityDecision {
  const _LifecycleAuthorityDecision.accepted(this.reason) : accepted = true;
  const _LifecycleAuthorityDecision.rejected(this.reason) : accepted = false;

  final bool accepted;
  final String reason;
}
