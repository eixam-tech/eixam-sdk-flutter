import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

import '../../device/ble_debug_registry.dart';
import '../../diagnostics/sdk_release_log.dart';
import '../../mappers/local_state_serializers.dart';
import '../../mappers/sos_incident_mapper.dart';
import '../../sdk/operational_realtime_client.dart';
import '../../sdk/sdk_mqtt_contract.dart';
import '../../sdk/sos_backend_identity_normalizer.dart';
import '../../sdk/sos_delivery_outbox.dart';
import '../../sdk/sos_incident_correlation.dart';
import '../../sdk/sos_origin_classifier.dart';
import '../datasources_local/shared_prefs_sdk_store.dart';
import '../datasources_remote/sos_remote_data_source.dart';
import '../dtos/sos_incident_dto.dart';
import 'mqtt_sos_lifecycle_update.dart';
import 'sos_runtime_rehydration_support.dart';

final class MqttAcceptedSosLifecycleTransition {
  const MqttAcceptedSosLifecycleTransition({
    required this.previousState,
    required this.state,
    required this.incident,
    required this.generation,
    required this.rawStatus,
    required this.source,
  });

  final SosState previousState;
  final SosState state;
  final SosIncident incident;
  final int generation;
  final String rawStatus;
  final String source;
}

final class MqttRemoteRelayLifecycleTransition {
  const MqttRemoteRelayLifecycleTransition({
    required this.state,
    required this.incidentId,
    required this.originatorNodeId,
    required this.relayNodeId,
    required this.relayHardwareId,
    required this.occurredAt,
    required this.rawStatus,
    required this.source,
    this.cycleKey,
  });

  final SosState state;
  final String incidentId;
  final int? originatorNodeId;
  final int? relayNodeId;
  final String? relayHardwareId;
  final DateTime occurredAt;
  final String rawStatus;
  final String source;
  final String? cycleKey;
}

class MqttOperationalSosRepository
    implements
        SosRepository,
        SosRuntimeRehydrationSupport,
        MqttOnlyLiveSosLifecycle,
        SosRuntimeSessionIsolation,
        SosRuntimeSessionScopeBinding,
        AuthoritativeActiveSosLookup,
        SosRejectedTerminalReconciliationSource {
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
    Duration externalRelayLifecycleContextTtl = const Duration(hours: 24),
    DateTime Function()? nowProvider,
    Duration cancelConfirmationWait = const Duration(seconds: 10),
    List<Duration>? deliveryBackoff,
    Duration deliveryRetryingAfter = const Duration(seconds: 10),
  }) : remoteDataSource = remoteDataSource ?? cancelRemoteDataSource,
       _cancelConfirmationWait = cancelConfirmationWait,
       _localStore = localStore,
       _destructiveRehydrationGracePeriod = destructiveRehydrationGracePeriod,
       _actuatorBufferTtl = actuatorBufferTtl,
       _processedHandoffWindow = processedHandoffWindow,
       _processedClockSkewTolerance = processedClockSkewTolerance,
       _externalRelayLifecycleContextTtl = externalRelayLifecycleContextTtl,
       _nowProvider = nowProvider ?? DateTime.now {
    _stateController.add(_stateMachine.current);
    _outbox = SosDeliveryOutbox(
      publish: _publishOutboxAction,
      readBackend: _readBackendForOutbox,
      store: localStore,
      clock: _nowProvider,
      confirmationWindow: mqttConfirmationWarningDelay,
      onConfirmed: _handleOutboxConfirmed,
      onExpired: _handleOutboxExpired,
      backoff: deliveryBackoff,
      retryingAfter: deliveryRetryingAfter,
    );
    _deliveryStatusSub = _outbox.watchStatus().listen(_applyDeliveryStatus);
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
  final Duration _actuatorBufferTtl;
  final Duration _processedHandoffWindow;
  final Duration _processedClockSkewTolerance;
  final Duration _externalRelayLifecycleContextTtl;
  final DateTime Function() _nowProvider;
  final Duration _cancelConfirmationWait;
  static const Duration _firstAttemptWait = Duration(seconds: 20);
  late final SosDeliveryOutbox _outbox;
  final Map<String, MqttOperationalSosRequest> _outboxRequests =
      <String, MqttOperationalSosRequest>{};
  final Map<String, SosIncidentDto> _outboxBackendConfirmations =
      <String, SosIncidentDto>{};

  /// Cycles queued in this process whose trigger never got a PUBACK: the
  /// backend cannot have them, so a cancel may settle locally.
  final Set<String> _neverPublishedTriggerCycles = <String>{};
  bool Function({
    required String source,
    required String? triggerSource,
    required String? cycleKey,
    required int? originatorNodeId,
    required int? packetId,
  })?
  preSosBackendPublishBlocker;
  int Function()? lifecycleGenerationProvider;
  final SosIncidentMapper _mapper = const SosIncidentMapper();
  SosStateMachine _stateMachine = SosStateMachine();
  final StreamController<SosState> _stateController =
      StreamController<SosState>.broadcast();
  final StreamController<SosRejectedTerminalReconciliationRequest>
  _rejectedTerminalReconciliationController =
      StreamController<SosRejectedTerminalReconciliationRequest>.broadcast();
  final StreamController<MqttAcceptedSosLifecycleTransition>
  _acceptedLifecycleTransitionController =
      StreamController<MqttAcceptedSosLifecycleTransition>.broadcast(
        sync: true,
      );
  final StreamController<MqttRemoteRelayLifecycleTransition>
  _remoteRelayLifecycleTransitionController =
      StreamController<MqttRemoteRelayLifecycleTransition>.broadcast(
        sync: true,
      );

  StreamSubscription<RealtimeEvent>? _realtimeSub;
  StreamSubscription<SosOutboxStatus>? _deliveryStatusSub;
  SosIncident? _activeIncident;
  String? _locallyClosedIncidentId;
  final Map<String, String?> _trustedLifecycleCorrelationIds =
      <String, String?>{};
  _PendingProcessedHandoff? _pendingProcessedHandoff;
  _PendingExternalRelayHandoff? _pendingExternalRelayHandoff;
  _ExternalRelayLifecycleContext? _externalRelayLifecycleContext;
  _PersistedExternalRelayLifecycleContext?
  _restoredExternalRelayLifecycleContext;
  String? _authenticatedSessionScope;
  final Map<String, DateTime> _externalRelaySosPublishDedupe =
      <String, DateTime>{};
  Timer? _mqttConfirmationWarningTimer;
  final Map<String, _BufferedActuatorUpdate> _bufferedActuatorUpdates =
      <String, _BufferedActuatorUpdate>{};
  final Map<String, DateTime> _handledMqttEvents = <String, DateTime>{};
  bool _disposed = false;
  int _rehydrationEpoch = 0;

  // Internal SDK lifecycle fence. Does not clear a persisted safety incident.
  void invalidatePendingRehydration() {
    _rehydrationEpoch++;
  }

  @visibleForTesting
  String? get debugLastTrustedCorrelationId =>
      _trustedLifecycleCorrelationIds.isEmpty
      ? null
      : _trustedLifecycleCorrelationIds.keys.last;

  Future<void> restoreState() async {
    if (_localStore == null) {
      return;
    }

    final incidentJson = await _localStore.readJson(
      SharedPrefsSdkStore.sosIncidentKey,
    );
    final stateRaw = await _localStore.readString(
      SharedPrefsSdkStore.sosStateKey,
    );
    _locallyClosedIncidentId = await _localStore.readString(
      SharedPrefsSdkStore.sosClosedIncidentKey,
    );
    final relayContextJson = await _localStore.readJson(
      SharedPrefsSdkStore.externalRelayLifecycleContextKey,
    );
    _restoredExternalRelayLifecycleContext =
        _PersistedExternalRelayLifecycleContext.tryParse(
          relayContextJson,
          now: _nowProvider().toUtc(),
          ttl: _externalRelayLifecycleContextTtl,
        );
    if (relayContextJson != null &&
        _restoredExternalRelayLifecycleContext == null) {
      await _localStore.remove(
        SharedPrefsSdkStore.externalRelayLifecycleContextKey,
      );
    }

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
    await _outbox.restore();
  }

  /// Set by the SDK: checks and, through the existing device registration
  /// calls, restores what the backend needs before an SOS it acknowledged but
  /// never confirmed is published again. Returns whether the outcome is
  /// known and the delivery issue (e.g.
  /// [SosIncident.deliveryIssueDeviceNotRegistered]) or null.
  Future<({bool known, String? issue})> Function(
    MqttOperationalSosRequest request,
  )?
  unconfirmedTriggerPrecheck;

  /// The precheck never holds an SOS republish for long (poor coverage, slow
  /// backend): past this the SOS is published anyway.
  @visibleForTesting
  Duration unconfirmedTriggerPrecheckTimeout = const Duration(seconds: 5);

  /// Delivery issue of the current SOS, kept across the incident updates of
  /// that SOS (no flicker on transient errors) and reset by the next
  /// trigger.
  String? _sosDeliveryIssue;

  SosIncident? _withDeliveryIssue(SosIncident? incident) {
    final issue = _sosDeliveryIssue;
    if (incident == null || issue == null || incident.deliveryIssue == issue) {
      return incident;
    }
    return incident.copyWith(deliveryIssue: issue);
  }

  Future<void> _runUnconfirmedTriggerPrecheck(
    MqttOperationalSosRequest request,
  ) async {
    final precheck = unconfirmedTriggerPrecheck;
    if (precheck == null) {
      return;
    }
    ({bool known, String? issue}) result;
    try {
      result = await precheck(request).timeout(
        unconfirmedTriggerPrecheckTimeout,
      );
    } catch (error) {
      sdkReleaseLog(
        'SOS_OUTBOX_PRECHECK_FAILED errorType=${error.runtimeType}',
      );
      return;
    }
    if (_disposed || !result.known) {
      // Unknown outcome: keep what the user already sees.
      return;
    }
    if (_sosDeliveryIssue != result.issue) {
      _sosDeliveryIssue = result.issue;
      sdkReleaseLog('SOS_OUTBOX_DELIVERY_ISSUE issue=${result.issue ?? "none"}');
      final incident = _activeIncident;
      if (incident != null) {
        _emitActuatorOnlyUpdate(incidentId: incident.id, version: null);
      }
    }
  }

  /// Mirrors "not sent yet, retrying" onto the unconfirmed local incident so
  /// hosts can say it clearly; cleared on confirmation or when delivered.
  void _applyDeliveryStatus(SosOutboxStatus status) {
    final incident = _activeIncident;
    if (_disposed || incident == null) {
      return;
    }
    final retrying =
        status.retrying && status.pendingTrigger && !incident.isBackendConfirmed;
    if (incident.isDeliveryRetrying == retrying) {
      return;
    }
    _activeIncident = incident.copyWith(isDeliveryRetrying: retrying);
    sdkReleaseLog(
      'SOS_OUTBOX_DELIVERY_STATUS retrying=$retrying '
      'attempts=${status.headAttempts}',
    );
    _emitActuatorOnlyUpdate(incidentId: incident.id, version: null);
  }

  /// A trigger is queued and not confirmed (read from the queue itself).
  bool get hasPendingSosTrigger => _outbox.hasPendingTrigger;

  /// Delivery state of SOS actions that the backend has not confirmed yet.
  SosOutboxStatus get deliveryStatus => _outbox.status;

  Stream<SosOutboxStatus> watchDeliveryStatus() => _outbox.watchStatus();

  /// Retry pending SOS deliveries now (connectivity regained, app resumed,
  /// native SOS event) instead of waiting for the backoff.
  void kickDelivery(String reason) => _outbox.kick(reason);

  /// A TAG/native cancel: the device already closed its SOS cycle, so the
  /// backend must follow even when no backend incident is known locally
  /// (F5). Durable and retried over MQTT until the backend confirms.
  Future<void> deliverDeviceCancel({
    required String reason,
    DateTime? observedAt,
  }) async {
    sdkReleaseLog('SOS_OUTBOX_DEVICE_CANCEL_REQUESTED reason=$reason');
    final current = _activeIncident;
    final observed = (observedAt ?? _nowProvider()).toUtc();
    final action = await _outbox.enqueueCancel(
      cycleKey: current?.cycleKey,
      observedAt: observed,
      scope: _authenticatedSessionScope,
    );
    // A cancel observed before the local SOS started belongs to an older
    // cycle: it must not settle this newer SOS.
    if (action == null ||
        (current != null && current.createdAt.toUtc().isAfter(observed))) {
      return;
    }
    _clearPendingMqttLifecycle(reason: 'device_cancel_requested');
    // The TAG is the truth for its own cycle: settle the local incident so a
    // stale open incident cannot block the next SOS (E_SOS_ALREADY_ACTIVE).
    const cancellable = <SosState>{
      SosState.triggeredLocal,
      SosState.sending,
      SosState.sent,
      SosState.acknowledged,
      SosState.cancelRequested,
    };
    if (current != null && cancellable.contains(_stateMachine.current)) {
      if (_stateMachine.current != SosState.cancelRequested) {
        _activeIncident = current.copyWith(state: SosState.cancelRequested);
        _emit(SosState.cancelRequested);
      }
      _clearCurrentIncidentAfterCancellation(
        current.copyWith(
          state: SosState.cancelled,
          terminalReason: SosTerminalReason.cancelledByUser,
        ),
      );
      await _persistState();
    }
  }

  @override
  Future<void> bindSosRuntimeSessionScope(String scope) async {
    // A repeated scope binding can replace credentials for the same account.
    // Its previous authenticated HTTP response must not mutate this runtime.
    _rehydrationEpoch++;
    final normalizedScope = scope.trim();
    if (normalizedScope.isEmpty) {
      return;
    }
    _authenticatedSessionScope = normalizedScope;
    final restored = _restoredExternalRelayLifecycleContext;
    _restoredExternalRelayLifecycleContext = null;
    if (restored == null) {
      return;
    }
    if (restored.sessionScope != normalizedScope) {
      await _clearPersistedExternalRelayLifecycleContext(
        reason: 'session_scope_mismatch',
      );
      return;
    }
    _externalRelayLifecycleContext = restored.context;
    BleDebugRegistry.instance.recordEvent(
      'SOS_REMOTE_RELAY_LIFECYCLE_CONTEXT_RESTORED '
      'incidentId=${restored.context.incidentId} '
      'originatorNodeId=${restored.context.originatorNodeId?.toString() ?? "none"} '
      'relayNodeId=${restored.context.relayNodeId?.toString() ?? "none"}',
    );
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
    final appOwnedSos =
        _isAppOwnedTriggerSource(triggerSource) ||
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
        id:
            incidentId ??
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
      BleDebugRegistry.instance.recordEvent(
        'SOS_POSITION_UNAVAILABLE continuing_backend_publish '
        'triggerSource=$triggerSource '
        'reason=location_never_blocks_activation',
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
      final latestIncident = _activeIncident;
      final authoritativeIncident =
          latestIncident != null &&
              latestIncident.isBackendConfirmed &&
              sosIncidentEvidenceMatches(incident, latestIncident)
          ? latestIncident
          : incident;
      _activeIncident = authoritativeIncident;
      _locallyClosedIncidentId = null;
      _rememberActiveLikeState();
      if (authoritativeIncident.isBackendConfirmed) {
        _emit(SosState.sent);
      } else {
        // Durably queued; `sent` only after backend confirmation.
        BleDebugRegistry.instance.recordEvent(
          'SOS_TRIGGER_AWAITING_BACKEND_CONFIRMATION state=sending',
        );
      }
      await _persistState();
      return _activeIncident ?? authoritativeIncident;
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
    final hasBackendActive =
        rehydration.outcome ==
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
    final hasDeviceIdentity =
        originatorNodeId != null ||
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
    final localIncidentId = 'sos-${DateTime.now().microsecondsSinceEpoch}';
    final effectiveCycleKey = cycleKey ?? incidentId ?? localIncidentId;
    final incident = SosIncident(
      id: localIncidentId,
      state: SosState.sending,
      createdAt: DateTime.now().toUtc(),
      source: relaySource,
      triggerSource: triggerSource,
      relaySource: relaySource,
      originatorNodeId: originatorNodeId,
      relayNodeId: relayNodeId,
      deviceId: deviceId,
      hardwareId: hardwareId,
      owner:
          _isAppOwnedTriggerSource(triggerSource) ||
              (originatorNodeId == null && relayNodeId == null)
          ? 'app'
          : 'device',
      cycleKey: effectiveCycleKey,
      message: message,
      positionSnapshot: positionSnapshot,
      provisionalIncidentId: incidentId != null && incidentId != localIncidentId
          ? incidentId
          : null,
    );
    final incidentBeforePublish = _activeIncident;
    // The broker can deliver Backend `processed` on the subscribed user topic
    // before the publish future resumes. Install the provisional identity first
    // so that event can pass the exact publish-timestamp authority gate.
    _activeIncident = incident;
    try {
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
        cycleKey: effectiveCycleKey,
        osWidgetActivation: osWidgetActivation,
        deviceBattery: deviceBattery,
        deviceCoverage: deviceCoverage,
        mobileBattery: mobileBattery,
        mobileCoverage: mobileCoverage,
      );
    } catch (_) {
      if (identical(_activeIncident, incident)) {
        _activeIncident = incidentBeforePublish;
      }
      rethrow;
    }
    BleDebugRegistry.instance.recordEvent(
      '[BACKGROUND_SOS] local_incident_created state=sending '
      'localIncidentId=${incident.id} backendIncidentId=none '
      'reason=queued_for_mqtt_delivery_awaiting_backend_confirmation',
    );
    final latestIncident = _activeIncident;
    if (latestIncident != null &&
        latestIncident.isBackendConfirmed &&
        sosIncidentEvidenceMatches(incident, latestIncident)) {
      return latestIncident;
    }
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
      final pendingExternalRelayHandoff = _PendingExternalRelayHandoff(
        occurredAt: timestamp.toUtc(),
        registeredAt: _nowProvider().toUtc(),
        originatorNodeId: identity.originatorNodeId,
        relayNodeId: relayNodeId,
        deviceId: identity.deviceId,
        hardwareId: identity.hardwareId,
        relayDeviceId: identity.relayDeviceId,
        relayHardwareId: relayHardwareId,
        cycleKey: _normalizeIdentity(cycleKey),
        source: relaySource ?? triggerSource ?? 'remote_lora_relay',
      );
      _pendingExternalRelayHandoff = pendingExternalRelayHandoff;
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
        if (identical(
          _pendingExternalRelayHandoff,
          pendingExternalRelayHandoff,
        )) {
          _pendingExternalRelayHandoff = null;
        }
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
    _pendingProcessedHandoff = _PendingProcessedHandoff(
      incidentId: _normalizeIdentity(incidentId),
      cycleKey: _normalizeIdentity(cycleKey),
      occurredAt: timestamp.toUtc(),
      registeredAt: _nowProvider().toUtc(),
    );
    BleDebugRegistry.instance.recordEvent(
      'SOS_TRIGGER_MQTT_PUBLISH_START source=$sourceLabel '
      'incidentId=${incidentId ?? "none"} correlationId=$correlationId '
      'cycleKey=${cycleKey ?? "none"} delivery=outbox',
    );
    // Durable before the first attempt: survives process death, retried over
    // MQTT with backoff until the backend confirms. Network failures never
    // surface here; they are delivery state, not an SOS failure.
    final outboxCycle =
        _normalizeIdentity(cycleKey) ?? _normalizeIdentity(incidentId);
    // A new SOS starts without the previous one's delivery issue.
    _sosDeliveryIssue = null;
    final action = await _outbox.enqueueTrigger(
      cycleKey: outboxCycle,
      payload: mqttOperationalSosRequestToOutboxJson(request),
      scope: _authenticatedSessionScope,
    );
    if (outboxCycle != null && action.attempts == 0 && !action.published) {
      _neverPublishedTriggerCycles.add(outboxCycle);
    }
    _outboxRequests[action.id] = request;
    // Foreground keeps today's immediate publish; a network failure is
    // delivery state handled by the outbox, never an SOS error.
    await _outbox.waitForAttempt(action, timeout: _firstAttemptWait);
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

    _activeIncident = _activeIncident!.copyWith(
      state: SosState.cancelRequested,
    );
    final cancellationTarget = _activeIncident!;
    _rememberActiveLikeState();
    _emit(SosState.cancelRequested);
    await _persistState();

    BleDebugRegistry.instance.recordEvent(
      'SOS_TRANSPORT_DECISION flow=sos_cancel transport=mqtt '
      'reason=cancel_must_use_mqtt',
    );
    // MQTT only (`cancel: true`), durable and retried until the backend
    // confirms; a trigger still queued for this SOS is superseded.
    final action = await _outbox.enqueueCancel(
      cycleKey: cancellationTarget.cycleKey,
      scope: _authenticatedSessionScope,
    );
    final confirmed =
        action != null &&
        await _outbox.waitForConfirmation(
          action,
          timeout: _cancelConfirmationWait,
        );
    final latest = _activeIncident;
    if (latest == null) {
      // Settled by the backend `cancelled` event, or the runtime was cleared
      // (session change): never claim cancelled without confirmation.
      return confirmed
          ? cancellationTarget.copyWith(state: SosState.cancelled)
          : cancellationTarget;
    }
    if (!sosIncidentEvidenceMatches(cancellationTarget, latest) ||
        _isTerminalState(latest.state)) {
      return latest;
    }
    final targetCycle = _normalizeIdentity(cancellationTarget.cycleKey);
    if (!confirmed &&
        !latest.isBackendConfirmed &&
        targetCycle != null &&
        _neverPublishedTriggerCycles.contains(targetCycle)) {
      // The trigger never reached the broker, so the backend cannot have
      // this SOS: settle locally. The queued MQTT cancel is still delivered.
      sdkReleaseLog('SOS_OUTBOX_CANCEL_LOCAL_SETTLE reason=trigger_never_published');
      _activeIncident = latest;
      final cancelled = latest.copyWith(
        state: SosState.cancelled,
        terminalReason: SosTerminalReason.cancelledByUser,
      );
      _clearCurrentIncidentAfterCancellation(cancelled);
      await _persistState();
      return cancelled;
    }
    if (!confirmed) {
      // Never show cancelled before the backend confirms: stays
      // cancelRequested while the outbox keeps retrying over MQTT; the
      // backend `cancelled` event or a backend read settles it.
      sdkReleaseLog('SOS_OUTBOX_CANCEL_PENDING_CONFIRMATION delivery=retrying');
      return latest;
    }
    return _settleConfirmedCancel(latest) ?? latest;
  }

  SosIncident? _settleConfirmedCancel(SosIncident target) {
    if (_stateMachine.current != SosState.cancelRequested) {
      return null;
    }
    final cancelled = target.copyWith(
      state: SosState.cancelled,
      terminalReason: target.terminalReason ?? SosTerminalReason.cancelledByUser,
    );
    sdkReleaseLog('SOS_OUTBOX_CANCEL_SETTLED confirmed=true');
    _clearCurrentIncidentAfterCancellation(cancelled);
    unawaited(_persistState());
    return cancelled;
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

    final resolutionTarget = _activeIncident!;
    try {
      final resolved = await remoteDataSource.resolveSos();
      final settledIncident = await _settleResolvedIncident(
        remoteDataSource: remoteDataSource,
        resolutionTarget: resolutionTarget,
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

  Future<SosIncident> _settleResolvedIncident({
    required SosRemoteDataSource remoteDataSource,
    required SosIncident resolutionTarget,
    required SosIncidentDto? resolvedDto,
  }) async {
    final latestAtResponse = _activeIncident;
    if (latestAtResponse != null &&
        !sosIncidentEvidenceMatches(resolutionTarget, latestAtResponse)) {
      return latestAtResponse;
    }
    if (resolvedDto != null) {
      final resolvedIncident = _mapper.toDomain(resolvedDto);
      if (!sosIncidentEvidenceMatches(resolutionTarget, resolvedIncident)) {
        return resolutionTarget;
      }
      return _applyBackendIncident(resolvedDto);
    }

    final activeAfterResolve = await remoteDataSource.getActiveSos();
    final latestAfterLookup = _activeIncident;
    if (latestAfterLookup != null &&
        !sosIncidentEvidenceMatches(resolutionTarget, latestAfterLookup)) {
      return latestAfterLookup;
    }
    if (activeAfterResolve != null) {
      final activeIncident = _mapper.toDomain(activeAfterResolve);
      if (!sosIncidentEvidenceMatches(resolutionTarget, activeIncident)) {
        return resolutionTarget;
      }
      return _applyBackendIncident(activeAfterResolve);
    }

    _activeIncident = resolutionTarget.copyWith(state: SosState.resolved);
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

  bool _isProvisionalLocalSosIncidentId(String id) {
    return id.startsWith('sos-') || id.startsWith('device-runtime-');
  }

  void _clearCurrentIncidentAfterCancellation(SosIncident cancelledIncident) {
    _activeIncident = cancelledIncident;
    _locallyClosedIncidentId = cancelledIncident.id;
    final terminalState = cancelledIncident.state == SosState.resolved
        ? SosState.resolved
        : SosState.cancelled;
    _emit(
      terminalState,
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
  Future<SosIncident?> getCurrentIncident() async =>
      _withDeliveryIssue(_activeIncident);

  @override
  Future<SosState> getSosState() async => _stateMachine.current;

  @override
  Stream<SosState> watchSosState() => _stateController.stream;

  @override
  Stream<SosIncident?> watchCurrentIncident() async* {
    yield _withDeliveryIssue(_activeIncident);
    // Delegate cancellation even while idle; retain await-for's error-then-done.
    yield* _stateController.stream.transform(
      StreamTransformer<SosState, SosIncident?>.fromHandlers(
        handleData: (_, sink) => sink.add(_withDeliveryIssue(_activeIncident)),
        handleError: (error, stack, sink) {
          sink.addError(error, stack);
          sink.close();
        },
      ),
    );
  }

  @override
  Future<SosHistoryPage> listSosHistory({
    String? cursor,
    int limit = 20,
  }) async {
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
            triggerSource:
                incident.triggerSource ??
                incident.source ??
                incident.relaySource,
            message: incident.message,
            deliveryChannel: incident.deliveryChannel,
            actuators: incident.actuators,
            creationTelemetry: item.creationTelemetry == null
                ? null
                : SosHistoryTelemetry(
                    id: item.creationTelemetry!.id,
                    occurredAt: DateTime.parse(
                      item.creationTelemetry!.occurredAt,
                    ),
                    latitude: item.creationTelemetry!.latitude,
                    longitude: item.creationTelemetry!.longitude,
                    altitude: item.creationTelemetry!.altitude,
                    deviceBattery: item.creationTelemetry!.deviceBattery,
                    deviceCoverage: item.creationTelemetry!.deviceCoverage,
                    mobileBattery: item.creationTelemetry!.mobileBattery,
                    mobileCoverage: item.creationTelemetry!.mobileCoverage,
                  ),
            trail: item.trail
                .map(
                  (p) => TrackingPosition(
                    latitude: p.latitude,
                    longitude: p.longitude,
                    timestamp: DateTime.parse(p.occurredAt),
                    altitude: p.altitude,
                    source: DeliveryMode.mobile,
                  ),
                )
                .toList(),
          );
        }).toList(),
        nextCursor: dto.nextCursor,
        hasMore: dto.hasMore,
      );
    });
  }

  @override
  Future<SosRuntimeRehydrationResult> rehydrateRuntimeStateFromBackend({
    bool terminalAbsenceExpected = false,
  }) async {
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
      final epoch = _rehydrationEpoch;
      final incidentBeforeLookup = _activeIncident;
      final stateBeforeLookup = _stateMachine.current;
      final active = await dataSource.getActiveSos();
      if (_disposed || epoch != _rehydrationEpoch) {
        return SosRuntimeRehydrationResult(
          outcome: SosRuntimeRehydrationOutcome.keptLocalFallback,
          resultingState: _stateMachine.current,
          diagnosticNote: 'E_SOS_REHYDRATION_SUPERSEDED_BY_SESSION_CHANGE',
        );
      }
      if (!identical(_activeIncident, incidentBeforeLookup) ||
          _stateMachine.current != stateBeforeLookup) {
        await _persistState();
        return SosRuntimeRehydrationResult(
          outcome: SosRuntimeRehydrationOutcome.keptLocalFallback,
          resultingState: _stateMachine.current,
          diagnosticNote: 'E_SOS_REHYDRATION_SUPERSEDED_BY_NEWER_RUNTIME',
        );
      }
      if (active == null) {
        if (!terminalAbsenceExpected && _shouldPreserveLocalFallback()) {
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

  Future<void> _publishOutboxAction(SosOutboxAction action) async {
    final actionScope = action.scope;
    if (actionScope != null) {
      final currentScope = _authenticatedSessionScope;
      if (currentScope == null) {
        // Session not bound yet (cold start): retry later.
        throw StateError('SOS outbox waiting for session scope');
      }
      if (currentScope != actionScope) {
        throw const SosOutboxDropAction('account_changed');
      }
    }
    switch (action.kind) {
      case SosOutboxActionKind.trigger:
        final request =
            _outboxRequests[action.id] ??
            mqttOperationalSosRequestFromOutboxJson(action.payload);
        if (request == null) {
          throw const SosException(
            'E_SOS_OUTBOX_PAYLOAD_INVALID',
            'E_SOS_OUTBOX_PAYLOAD_INVALID',
          );
        }
        _outboxRequests[action.id] = request;
        var outgoing = request;
        if (action.published) {
          // The broker acknowledged an earlier attempt but the backend never
          // confirmed it (it rejects silently while the account has no
          // registered TAG): restore the registration, then publish on a new
          // connection so the broker re-runs auth.
          await _runUnconfirmedTriggerPrecheck(request);
          outgoing = request.copyWith(forceFreshConnection: true);
        }
        final handoff = _pendingProcessedHandoff;
        if (handoff == null ||
            _normalizeIdentity(request.cycleKey) == handoff.cycleKey) {
          // Keep the `processed` authority window open across retries.
          _pendingProcessedHandoff = _PendingProcessedHandoff(
            incidentId: _normalizeIdentity(request.incidentId),
            cycleKey: _normalizeIdentity(request.cycleKey),
            occurredAt: request.timestamp.toUtc(),
            registeredAt: _nowProvider().toUtc(),
          );
        }
        await realtimeClient.publishOperationalSos(outgoing);
        final publishedCycle = _normalizeIdentity(action.cycleKey);
        if (publishedCycle != null) {
          _neverPublishedTriggerCycles.remove(publishedCycle);
        }
      case SosOutboxActionKind.cancel:
        final timestamp =
            DateTime.tryParse('${action.payload['timestamp']}') ??
            action.createdAt;
        await realtimeClient.publishOperationalSosCancel(timestamp: timestamp);
    }
  }

  Future<SosOutboxBackendCheck> _readBackendForOutbox(
    SosOutboxAction action,
  ) async {
    final dataSource = remoteDataSource;
    if (dataSource == null) {
      return SosOutboxBackendCheck.unknown;
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_BACKEND_CONFIRMATION_TIMEOUT transport=mqtt '
      'action=${action.kind.name} backendRead=active_sos',
    );
    final activeDto = await dataSource.getActiveSos();
    final active = activeDto == null ? null : _mapper.toDomain(activeDto);
    final open =
        active != null &&
        _isBackendActiveEvidenceState(active.state) &&
        !classifySosIncidentOrigin(active).isExternalOnly;
    switch (action.kind) {
      case SosOutboxActionKind.trigger:
        if (open) {
          _outboxBackendConfirmations[action.id] = activeDto!;
          return SosOutboxBackendCheck.confirmed;
        }
        // No open incident: not confirmed. History is not used as proof (the
        // backend ignores our incident identity, so an earlier incident
        // could be mistaken for this one and the SOS would be lost). A
        // delivered-then-closed SOS is retired by its terminal event.
        return SosOutboxBackendCheck.notConfirmed;
      case SosOutboxActionKind.cancel:
        return open
            ? SosOutboxBackendCheck.notConfirmed
            : SosOutboxBackendCheck.confirmed;
    }
  }

  /// A trigger the backend never confirmed within its lifetime: say so
  /// instead of leaving the UI on "awaiting confirmation" forever.
  void _handleOutboxExpired(SosOutboxAction action) {
    _outboxRequests.remove(action.id);
    if (action.kind != SosOutboxActionKind.trigger) {
      return;
    }
    final incident = _activeIncident;
    final cycle = _normalizeIdentity(action.cycleKey);
    if (incident == null ||
        incident.isBackendConfirmed ||
        (cycle != null && _normalizeIdentity(incident.cycleKey) != cycle)) {
      return;
    }
    _activeIncident = incident.copyWith(
      state: SosState.failed,
      isDeliveryRetrying: false,
    );
    if (_emit(SosState.failed, reason: 'outbox_delivery_expired')) {
      unawaited(_persistState());
    }
  }

  void _handleOutboxConfirmed(SosOutboxAction action, String source) {
    if (action.kind == SosOutboxActionKind.cancel) {
      final target = _activeIncident;
      // Whatever proved it (event or backend read), this incident is closed:
      // a late event of it is never evidence for a newer SOS (M1).
      final targetId = _normalizeIdentity(target?.id);
      if (target != null &&
          targetId != null &&
          target.isBackendConfirmed &&
          !_isProvisionalLocalSosIncidentId(target.id)) {
        _rememberClosedBackendIncident(targetId);
      }
      if (target != null && _stateMachine.current == SosState.cancelRequested) {
        _settleConfirmedCancel(target);
      }
      return;
    }
    _outboxRequests.remove(action.id);
    final readDto = _outboxBackendConfirmations.remove(action.id);
    if (readDto != null) {
      _applyOutboxTriggerConfirmation(readDto, action: action);
      return;
    }
    final incident = _activeIncident;
    if (incident == null || incident.isBackendConfirmed) {
      return;
    }
    // Confirmed by a realtime event the authority gate did not apply to the
    // local incident: read the backend once to promote it.
    unawaited(() async {
      try {
        final activeDto = await remoteDataSource?.getActiveSos();
        if (activeDto != null) {
          _applyOutboxTriggerConfirmation(activeDto, action: action);
        }
      } catch (error) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_BACKEND_CONFIRMATION_RECONCILIATION_FAILED '
          'errorType=${error.runtimeType}',
        );
      }
    }());
  }

  /// Promotes the local unconfirmed incident to the backend incident after
  /// the outbox confirmed delivery from a backend read.
  void _applyOutboxTriggerConfirmation(
    SosIncidentDto activeDto, {
    required SosOutboxAction action,
  }) {
    final current = _activeIncident;
    if (_disposed ||
        current == null ||
        current.isBackendConfirmed ||
        !_isActiveLikeState(_stateMachine.current) ||
        _stateMachine.current == SosState.cancelRequested) {
      return;
    }
    // Only the local incident this action delivered (a newer generation
    // after a session change is a different SOS).
    final actionCycle = _normalizeIdentity(action.cycleKey);
    if (actionCycle != null &&
        _normalizeIdentity(current.cycleKey) != actionCycle &&
        _normalizeIdentity(current.id) != actionCycle) {
      return;
    }
    final backendIncident = _mapper.toDomain(activeDto);
    final directIdentityMatch = sosIncidentEvidenceMatches(
      current,
      backendIncident,
    );
    final actuatorCanonicalMatch = _hasAuthenticatedActuatorCanonicalMatch(
      current,
      backendIncident,
    );
    // One open SOS per user: an open own-user incident observed after this
    // phone delivered its trigger is that trigger's incident.
    final ownOpenIncident =
        !classifySosIncidentOrigin(backendIncident).isExternalOnly &&
        _isBackendActiveEvidenceState(backendIncident.state) &&
        !backendIncident.createdAt.toUtc().isBefore(
          action.createdAt.subtract(const Duration(minutes: 2)),
        );
    if (!directIdentityMatch && !actuatorCanonicalMatch && !ownOpenIncident) {
      return;
    }
    final previousState = _stateMachine.current;
    final confirmed = backendIncident.copyWith(
      deliveryChannel: current.deliveryChannel,
      provisionalIncidentId: current.provisionalIncidentId ?? current.id,
      preservedLocalOwnership: true,
      isBackendConfirmed: true,
    );
    _activeIncident = confirmed;
    _pendingProcessedHandoff = null;
    BleDebugRegistry.instance.recordEvent(
      'SOS_BACKEND_CONFIRMATION_REST_ACCEPTED reason='
      '${directIdentityMatch
          ? "incident_identity_match"
          : actuatorCanonicalMatch
          ? "authenticated_actuator_canonical_match"
          : "own_open_incident_after_delivery"}',
    );
    BleDebugRegistry.instance.recordEvent(
      'SOS_CANONICAL_INCIDENT_HANDOFF '
      'source=rest_authoritative_reconciliation '
      'preservedLocalOwnership=true',
    );
    final accepted = _emit(
      confirmed.state,
      previousIncident: current,
      incomingIncident: confirmed,
      reason: 'outbox_backend_confirmation',
    );
    if (accepted && !_acceptedLifecycleTransitionController.isClosed) {
      _acceptedLifecycleTransitionController.add(
        MqttAcceptedSosLifecycleTransition(
          previousState: previousState,
          state: confirmed.state,
          incident: confirmed,
          generation: lifecycleGenerationProvider?.call() ?? 0,
          rawStatus: 'rest_active',
          source: 'rest:outbox_confirmation',
        ),
      );
    }
    if (actuatorCanonicalMatch) {
      _applyBufferedActuatorUpdate(backendIncident.id);
    }
    _rememberActiveLikeStateIfNeeded(confirmed.state);
    unawaited(_persistState());
    _logProgressSummary(confirmed);
  }

  /// Backend lifecycle events confirm the outbox head regardless of the local
  /// incident authority gate (the local incident may be gone after a cancel).
  ///
  /// The backend ignores our incident identity, so an event proves delivery
  /// of the head only when it can be the head's own effect (M1):
  /// - the head already reached the broker (PUBACK): `sos/events` is not
  ///   retained, so an event evaluated now arrived after that PUBACK;
  /// - its incident was not already seen closed: a late or redelivered event
  ///   of an earlier incident is never proof for a newer SOS or cancel.
  /// Anything else is left to the outbox retry and its backend read.
  ///
  /// Returns true when [update] is an open-state event of an incident already
  /// seen closed: the caller must not apply it to the local SOS either.
  bool _confirmOutboxFromRealtime(MqttSosLifecycleUpdate update) {
    if (!update.authenticatedUserScoped || _isExternalOnlyLifecycle(update)) {
      return false;
    }
    final incidentId = _normalizeIdentity(update.incidentId);
    final closedBefore =
        incidentId != null && _closedBackendIncidentIds.contains(incidentId);
    final state = update.state;
    final terminal = state == SosState.cancelled || state == SosState.resolved;
    if (terminal && incidentId != null) {
      _rememberClosedBackendIncident(incidentId);
    }
    if (closedBefore) {
      sdkReleaseLog(
        'SOS_OUTBOX_CONFIRMATION_REJECTED reason=incident_already_closed '
        'eventType=${update.eventType}',
      );
      return !terminal;
    }
    if (!terminal &&
        (update.eventType == 'processed' ||
            state == SosState.sent ||
            state == SosState.acknowledged)) {
      _outbox.confirm(
        SosOutboxActionKind.trigger,
        source: 'mqtt_${update.eventType}',
        matches: (head) => head.published,
      );
    }
    if (terminal) {
      // The backend closed the incident this trigger was delivered into
      // (one open SOS per user); republishing would open a zombie SOS.
      _outbox.confirm(
        SosOutboxActionKind.trigger,
        source: 'mqtt_${state!.name}_after_puback',
        matches: (head) => head.published,
      );
      final local = _activeIncident;
      // A terminal event for another incident is not this cancel's proof.
      final forLocalIncident =
          local == null ||
          !local.isBackendConfirmed ||
          _isProvisionalLocalSosIncidentId(local.id) ||
          _sameIdentity(update.incidentId, local.id);
      if (forLocalIncident) {
        _outbox.confirm(
          SosOutboxActionKind.cancel,
          source: 'mqtt_${state.name}',
          matches: (head) => head.published,
        );
      }
    }
    return false;
  }

  /// Backend incidents this phone saw closed (bounded, newest last).
  final List<String> _closedBackendIncidentIds = <String>[];

  void _rememberClosedBackendIncident(String incidentId) {
    _closedBackendIncidentIds
      ..remove(incidentId)
      ..add(incidentId);
    if (_closedBackendIncidentIds.length > 32) {
      _closedBackendIncidentIds.removeAt(0);
    }
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
    _pendingProcessedHandoff = null;
    _pendingExternalRelayHandoff = null;
    _externalRelayLifecycleContext = null;
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
    _rehydrationEpoch++;
    _clearPendingMqttLifecycle(reason: 'session_cleared');
    _authenticatedSessionScope = null;
    await _clearPersistedExternalRelayLifecycleContext(
      reason: 'session_cleared',
    );
    _activeIncident = null;
    _locallyClosedIncidentId = null;
    _trustedLifecycleCorrelationIds.clear();
    _externalRelaySosPublishDedupe.clear();
    _outboxRequests.clear();
    _outboxBackendConfirmations.clear();
    _neverPublishedTriggerCycles.clear();
    _closedBackendIncidentIds.clear();
    await _outbox.clear(reason: 'session_cleared');
    _setState(SosState.idle);
    await _persistState();
  }

  Future<void> dispose() async {
    _disposed = true;
    _rehydrationEpoch++;
    _clearPendingMqttLifecycle(reason: 'repository_disposed');
    await _deliveryStatusSub?.cancel();
    await _outbox.dispose();
    await _realtimeSub?.cancel();
    await _stateController.close();
    await _acceptedLifecycleTransitionController.close();
    await _remoteRelayLifecycleTransitionController.close();
    await _rejectedTerminalReconciliationController.close();
  }

  Stream<MqttAcceptedSosLifecycleTransition>
  watchAcceptedLifecycleTransitions() =>
      _acceptedLifecycleTransitionController.stream;

  Stream<MqttRemoteRelayLifecycleTransition>
  watchRemoteRelayLifecycleTransitions() =>
      _remoteRelayLifecycleTransitionController.stream;

  @override
  Stream<SosRejectedTerminalReconciliationRequest>
  watchRejectedTerminalReconciliations() =>
      _rejectedTerminalReconciliationController.stream;

  void _handleRealtimeEvent(RealtimeEvent event) {
    final update = MqttSosLifecycleUpdate.fromRealtimeEvent(event);
    final rawStatus = _rawMqttStatus(event);
    BleDebugRegistry.instance.recordEvent(
      'SOS_BACKEND_EVENT_RX '
      'incidentId=${update?.incidentId ?? _eventIncidentId(event) ?? "none"} '
      'rawStatus=$rawStatus '
      'normalizedStatus=${update?.state?.name ?? "unknown"} '
      'revision=${_mqttEventRevision(event)} '
      'timestamp=${event.timestamp.toUtc().toIso8601String()} '
      'source=mqtt:${update?.topicCategory ?? _mqttTopicCategory(event)} '
      'payloadPresent=${event.payload != null}',
    );
    if (update == null) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_MQTT_EVENT_PARSE_REJECTED '
        'reason=${_mqttParseRejectionReason(event)} '
        'eventType=${event.type.trim().isEmpty ? "unknown" : event.type}',
      );
      return;
    }
    if (_confirmOutboxFromRealtime(update) &&
        !_isTerminalState(_stateMachine.current)) {
      // An open-state event of an incident this phone already saw closed is
      // never evidence for the current SOS (M1). A terminal local state is
      // already protected by the regression block below.
      BleDebugRegistry.instance.recordEvent(
        'SOS_MQTT_EVENT_AUTHORITY_REJECTED reason=incident_already_closed '
        'eventType=${update.eventType}',
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
    if (_handleMatchingRemoteRelayLifecycle(update, rawStatus: rawStatus)) {
      return;
    }
    final authority = _lifecycleAuthorityFor(update);
    BleDebugRegistry.instance.recordEvent(
      'SOS_BACKEND_EVENT_CORRELATION '
      'incidentId=${update.incidentId} '
      'currentIncidentId=${_activeIncident?.id ?? "none"} '
      'generation=${lifecycleGenerationProvider?.call() ?? 0} '
      'correlated=${authority.accepted} reason=${authority.reason}',
    );
    if (!authority.accepted) {
      _requestAuthenticatedTerminalReconciliationIfEligible(update);
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
    if (update.eventType == 'processed') {
      _pendingProcessedHandoff = null;
      _pendingExternalRelayHandoff = null;
    }
    _rememberMqttEvent(update);
    if (!_isActiveLikeState(_stateMachine.current)) {
      if (_isTerminalState(_stateMachine.current) &&
          (_mqttUpdateRepresentsOpenState(update, rawStatus) ||
              update.eventType == 'sos.actuator_update')) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_TERMINAL_REGRESSION_BLOCKED '
          'incidentId=${update.incidentId} '
          'generation=${lifecycleGenerationProvider?.call() ?? 0} '
          'terminalState=${_stateMachine.current.name} '
          'incomingRawStatus=$rawStatus '
          'incomingNormalizedStatus=${_normalizedMqttStatusLabel(update, rawStatus)} '
          'incomingEventType=${update.eventType} '
          'source=mqtt:${update.topicCategory ?? "unknown"} '
          'reason=same_incident_terminal_monotonicity',
        );
      }
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
        trustedCanonicalHandoff:
            !previousIncident.isBackendConfirmed &&
            _isProvisionalLocalSosIncidentId(previousIncident.id),
      );
    }
    var currentIncident = _activeIncident!;
    var shouldPersist =
        !currentIncident.isBackendConfirmed ||
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
    // Publish the incident evidence and its state as one repository
    // observation. Stream listeners may run before this stack unwinds, so the
    // incident must already carry the accepted state when the state event is
    // delivered.
    final previousState = _stateMachine.current;
    _activeIncident = nextIncident;
    final accepted = _emit(
      state,
      previousIncident: currentIncident,
      incomingIncident: nextIncident,
      reason: 'realtime_event',
    );
    BleDebugRegistry.instance.recordEvent(
      'SOS_BACKEND_EVENT_LIFECYCLE_DECISION '
      'rawStatus=$rawStatus normalizedStatus=${state.name} '
      'previousLifecycle=${previousState.name} '
      'requestedLifecycle=${state.name} admitted=$accepted '
      'reason=${accepted ? "repository_transition_accepted" : "repository_transition_rejected"}',
    );
    if (!accepted) {
      _activeIncident = currentIncident;
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
    if (!_acceptedLifecycleTransitionController.isClosed) {
      _acceptedLifecycleTransitionController.add(
        MqttAcceptedSosLifecycleTransition(
          previousState: previousState,
          state: state,
          incident: nextIncident,
          generation: lifecycleGenerationProvider?.call() ?? 0,
          rawStatus: rawStatus,
          source: 'mqtt:${update.topicCategory ?? "unknown"}',
        ),
      );
    }
    _rememberActiveLikeStateIfNeeded(state);
    unawaited(_persistState());
    _logProgressSummary(nextIncident);
    if (incidentIdentifierChanged) {
      _applyBufferedActuatorUpdate(update.incidentId);
    }
  }

  void _requestAuthenticatedTerminalReconciliationIfEligible(
    MqttSosLifecycleUpdate update,
  ) {
    final terminalState = update.state;
    if (terminalState == null ||
        !update.authenticatedUserScoped ||
        (terminalState != SosState.cancelled &&
            terminalState != SosState.resolved) ||
        _rejectedTerminalReconciliationController.isClosed) {
      return;
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_TERMINAL_RECONCILIATION_REQUESTED '
      'reason=authenticated_terminal_identity_unproven '
      'terminal=${terminalState.name}',
    );
    _rejectedTerminalReconciliationController.add(
      SosRejectedTerminalReconciliationRequest(terminalState: terminalState),
    );
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

    if (_hasMqttIdentityConflict(update, activeIncident)) {
      _logLifecycleAuthorityRejected(
        update: update,
        activeIncidentId: activeIncident.id,
        reason: 'identity_conflict',
        diagnostic: 'MQTT_SOS_LIFECYCLE_REJECTED_IDENTITY_MISMATCH',
      );
      return const _LifecycleAuthorityDecision.rejected('identity_conflict');
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

    if (_sameIdentity(update.clientIncidentId, activeIncident.id) ||
        _sameIdentity(
          update.clientIncidentId,
          activeIncident.provisionalIncidentId,
        )) {
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

    if (_hasExactProcessedHandoffMatch(update, activeIncident)) {
      _logLifecycleAuthorityAccepted(
        update: update,
        activeIncidentId: activeIncident.id,
        reason: 'processed_publish_timestamp_match',
        diagnostic: 'MQTT_SOS_LIFECYCLE_ACCEPTED_PROCESSED_HANDOFF',
      );
      return const _LifecycleAuthorityDecision.accepted(
        'processed_publish_timestamp_match',
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

    if (_isUserScopedAcknowledgementHandoff(update, activeIncident)) {
      _logLifecycleAuthorityAccepted(
        update: update,
        activeIncidentId: activeIncident.id,
        reason: 'user_scoped_ack_handoff',
        diagnostic: 'MQTT_SOS_LIFECYCLE_ACCEPTED_USER_SCOPED_ACK',
      );
      return const _LifecycleAuthorityDecision.accepted(
        'user_scoped_ack_handoff',
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

  bool _handleMatchingRemoteRelayLifecycle(
    MqttSosLifecycleUpdate update, {
    required String rawStatus,
  }) {
    final pending = _pendingExternalRelayHandoff;
    final occurredAt = update.incidentOccurredAt;
    final matchesPendingCanonical =
        (_activeIncident == null || _isTerminalState(_activeIncident!.state)) &&
        pending != null &&
        update.eventType == 'processed' &&
        update.authenticatedUserScoped &&
        update.state != null &&
        _isActiveLikeState(update.state!) &&
        occurredAt != null &&
        occurredAt.toUtc() == pending.occurredAt &&
        _nowProvider().toUtc().difference(pending.registeredAt) <=
            _processedHandoffWindow;
    if (matchesPendingCanonical) {
      final context = _ExternalRelayLifecycleContext(
        incidentId: update.incidentId,
        cycleKey: pending.cycleKey,
        occurredAt: pending.occurredAt,
        originatorNodeId: pending.originatorNodeId,
        relayNodeId: pending.relayNodeId,
        relayHardwareId: pending.relayHardwareId,
      );
      _externalRelayLifecycleContext = context;
      unawaited(_persistExternalRelayLifecycleContext(context));
      _pendingExternalRelayHandoff = null;
      _emitRemoteRelayLifecycleTransition(
        context: context,
        state: update.state!,
        rawStatus: rawStatus,
        source: 'mqtt:${update.topicCategory ?? "unknown"}',
      );
      BleDebugRegistry.instance.recordEvent(
        'SOS_MQTT_EVENT_AUTHORITY_ACCEPTED '
        'reason=remote_canonical_correlation eventType=${update.eventType} '
        'originatorNodeId=${pending.originatorNodeId?.toString() ?? "none"} '
        'relayNodeId=${pending.relayNodeId?.toString() ?? "none"} '
        'relayDeviceId=${pending.relayDeviceId ?? "none"} '
        'relayHardwareId=${pending.relayHardwareId ?? "none"} '
        'localStateMutation=false publicIncident=false',
      );
      return true;
    }

    final context = _externalRelayLifecycleContext;
    final state = update.state;
    if (context == null ||
        state == null ||
        !_sameIdentity(update.incidentId, context.incidentId) ||
        !_isTrustedUserScopedAckTopic(update)) {
      return false;
    }
    if (context.cycleKey?.startsWith('lora:') == true &&
        (update.incidentOccurredAt == null ||
            update.incidentOccurredAt!.toUtc() != context.occurredAt)) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_REMOTE_RELAY_LIFECYCLE_REJECTED reason=canonical_cycle_timestamp_mismatch localStateMutation=false',
      );
      return true; // consumed as a rejected remote event; never fall into the local lifecycle
    }
    _emitRemoteRelayLifecycleTransition(
      context: context,
      state: state,
      rawStatus: rawStatus,
      source: 'mqtt:${update.topicCategory ?? "unknown"}',
    );
    if (_isTerminalState(state)) {
      _clearExternalRelaySosPublishDedupe(context);
      _externalRelayLifecycleContext = null;
      unawaited(
        _clearPersistedExternalRelayLifecycleContext(
          reason: 'terminal_${state.name}',
        ),
      );
    }
    return true;
  }

  void _clearExternalRelaySosPublishDedupe(
    _ExternalRelayLifecycleContext context,
  ) {
    final originatorNodeId = context.originatorNodeId?.toString() ?? 'none';
    final relayNodeId = context.relayNodeId?.toString() ?? 'none';
    _externalRelaySosPublishDedupe.removeWhere((key, _) {
      final parts = key.split(':');
      return parts.length >= 5 &&
          parts[0] == 'remote_lora_relay' &&
          parts[1] == originatorNodeId &&
          parts[2] == relayNodeId;
    });
    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS repository_publish_dedupe_rearmed '
      'reason=terminal_correlated '
      'originatorNodeId=$originatorNodeId relayNodeId=$relayNodeId',
    );
  }

  Future<void> _persistExternalRelayLifecycleContext(
    _ExternalRelayLifecycleContext context,
  ) async {
    final store = _localStore;
    final sessionScope = _authenticatedSessionScope;
    final incidentId = context.incidentId.trim();
    final relayHardwareId = context.relayHardwareId?.trim();
    if (store == null ||
        sessionScope == null ||
        sessionScope.isEmpty ||
        incidentId.isEmpty ||
        context.originatorNodeId == null ||
        context.relayNodeId == null ||
        context.originatorNodeId == context.relayNodeId ||
        relayHardwareId == null ||
        relayHardwareId.isEmpty) {
      return;
    }
    final persistedAt = _nowProvider().toUtc();
    await store.saveJson(
      SharedPrefsSdkStore.externalRelayLifecycleContextKey,
      <String, dynamic>{
        'sessionScope': sessionScope,
        'incidentId': incidentId,
        if (context.cycleKey != null) 'cycleKey': context.cycleKey,
        'occurredAt': context.occurredAt.toUtc().toIso8601String(),
        if (context.originatorNodeId != null)
          'originatorNodeId': context.originatorNodeId,
        if (context.relayNodeId != null) 'relayNodeId': context.relayNodeId,
        'relayHardwareId': relayHardwareId,
        'persistedAt': persistedAt.toIso8601String(),
      },
    );
  }

  Future<void> _clearPersistedExternalRelayLifecycleContext({
    required String reason,
  }) async {
    _restoredExternalRelayLifecycleContext = null;
    final store = _localStore;
    if (store == null) {
      return;
    }
    await store.remove(SharedPrefsSdkStore.externalRelayLifecycleContextKey);
    BleDebugRegistry.instance.recordEvent(
      'SOS_REMOTE_RELAY_LIFECYCLE_CONTEXT_CLEARED reason=$reason',
    );
  }

  void _emitRemoteRelayLifecycleTransition({
    required _ExternalRelayLifecycleContext context,
    required SosState state,
    required String rawStatus,
    required String source,
  }) {
    if (!_remoteRelayLifecycleTransitionController.isClosed) {
      _remoteRelayLifecycleTransitionController.add(
        MqttRemoteRelayLifecycleTransition(
          state: state,
          incidentId: context.incidentId,
          cycleKey: context.cycleKey,
          originatorNodeId: context.originatorNodeId,
          relayNodeId: context.relayNodeId,
          relayHardwareId: context.relayHardwareId,
          occurredAt: context.occurredAt,
          rawStatus: rawStatus,
          source: source,
        ),
      );
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_REMOTE_RELAY_LIFECYCLE_CORRELATED '
      'incidentId=${context.incidentId} state=${state.name} '
      'originatorNodeId=${context.originatorNodeId?.toString() ?? "none"} '
      'relayNodeId=${context.relayNodeId?.toString() ?? "none"} '
      'localStateMutation=false publicIncident=false source=$source',
    );
  }

  bool _hasMqttIdentityConflict(
    MqttSosLifecycleUpdate update,
    SosIncident activeIncident,
  ) {
    final cycleKey = _normalizeIdentity(update.cycleKey);
    final activeCycleKey = _normalizeIdentity(activeIncident.cycleKey);
    if (cycleKey != null &&
        activeCycleKey != null &&
        cycleKey != activeCycleKey) {
      return true;
    }

    final clientIncidentId = _normalizeIdentity(update.clientIncidentId);
    if (clientIncidentId != null &&
        !_sameIdentity(clientIncidentId, activeIncident.id) &&
        !_sameIdentity(
          clientIncidentId,
          activeIncident.provisionalIncidentId,
        )) {
      return true;
    }

    final correlationId = _normalizeIdentity(update.correlationId);
    if (correlationId != null &&
        !_hasTrustedCorrelationMatch(update, activeIncident)) {
      return true;
    }

    return activeIncident.isBackendConfirmed &&
        !_sameIdentity(update.incidentId, activeIncident.id);
  }

  bool _hasExactProcessedHandoffMatch(
    MqttSosLifecycleUpdate update,
    SosIncident activeIncident,
  ) {
    final pending = _pendingProcessedHandoff;
    final occurredAt = update.incidentOccurredAt;
    if (update.eventType != 'processed' ||
        !update.authenticatedUserScoped ||
        pending == null ||
        occurredAt == null ||
        _nowProvider().toUtc().difference(pending.registeredAt) >
            _processedHandoffWindow ||
        occurredAt.toUtc() != pending.occurredAt ||
        activeIncident.createdAt.toUtc() != pending.occurredAt) {
      return false;
    }
    final pendingIncidentId = pending.incidentId;
    if (pendingIncidentId != null &&
        !_sameIdentity(pendingIncidentId, activeIncident.id) &&
        !_sameIdentity(
          pendingIncidentId,
          activeIncident.provisionalIncidentId,
        )) {
      return false;
    }
    final pendingCycleKey = pending.cycleKey;
    if (pendingCycleKey != null &&
        !_sameIdentity(pendingCycleKey, activeIncident.cycleKey)) {
      return false;
    }
    return true;
  }

  bool _hasAuthenticatedActuatorCanonicalMatch(
    SosIncident current,
    SosIncident backendIncident,
  ) {
    final buffered = _bufferedActuatorUpdates[backendIncident.id];
    if (buffered == null ||
        buffered.update.eventType != 'sos.actuator_update' ||
        !buffered.update.authenticatedUserScoped ||
        !_sameIdentity(buffered.update.incidentId, backendIncident.id) ||
        !_hasCurrentPendingProcessedHandoff(current) ||
        !_isProcessedTimestampCompatible(buffered.update, current) ||
        _isExternalOnlyLifecycle(buffered.update)) {
      return false;
    }
    if (_differentIdentity(current.cycleKey, backendIncident.cycleKey) ||
        _differentIdentity(current.deviceId, backendIncident.deviceId) ||
        _differentIdentity(current.hardwareId, backendIncident.hardwareId) ||
        (current.originatorNodeId != null &&
            backendIncident.originatorNodeId != null &&
            current.originatorNodeId != backendIncident.originatorNodeId)) {
      return false;
    }
    return true;
  }

  bool _hasCurrentPendingProcessedHandoff(SosIncident activeIncident) {
    final pending = _pendingProcessedHandoff;
    if (pending == null ||
        _nowProvider().toUtc().difference(pending.registeredAt) >
            _processedHandoffWindow ||
        activeIncident.createdAt.toUtc() != pending.occurredAt) {
      return false;
    }
    final pendingIncidentId = pending.incidentId;
    if (pendingIncidentId != null &&
        !_sameIdentity(pendingIncidentId, activeIncident.id) &&
        !_sameIdentity(
          pendingIncidentId,
          activeIncident.provisionalIncidentId,
        )) {
      return false;
    }
    final pendingCycleKey = pending.cycleKey;
    return pendingCycleKey == null ||
        _sameIdentity(pendingCycleKey, activeIncident.cycleKey);
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

  bool _isUserScopedAcknowledgementHandoff(
    MqttSosLifecycleUpdate update,
    SosIncident activeIncident,
  ) {
    if (update.state != SosState.acknowledged ||
        !_isTrustedUserScopedAckTopic(update) ||
        activeIncident.isBackendConfirmed ||
        !_isActiveLikeState(_stateMachine.current) ||
        !_isProvisionalLocalSosIncidentId(activeIncident.id)) {
      return false;
    }
    final eventAt = update.eventTimestamp.toUtc();
    final createdAt = activeIncident.createdAt.toUtc();
    final earliest = createdAt.subtract(_processedClockSkewTolerance);
    final futureLimit = _nowProvider().toUtc().add(
      _processedClockSkewTolerance,
    );
    return !eventAt.isBefore(earliest) && !eventAt.isAfter(futureLimit);
  }

  bool _isTrustedUserScopedAckTopic(MqttSosLifecycleUpdate update) {
    if (update.authenticatedUserScoped) {
      return true;
    }
    final topicCategory = update.topicCategory?.trim().toLowerCase();
    return topicCategory == 'internal' || topicCategory == 'legacy_alias';
  }

  bool _isProcessedTimestampCompatible(
    MqttSosLifecycleUpdate update,
    SosIncident activeIncident,
  ) {
    final eventAt = update.eventTimestamp.toUtc();
    final createdAt = activeIncident.createdAt.toUtc();
    final earliest = createdAt.subtract(_processedClockSkewTolerance);
    final latest = createdAt.add(_processedHandoffWindow);
    final futureLimit = _nowProvider().toUtc().add(
      _processedClockSkewTolerance,
    );
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
        _hasCurrentPendingProcessedHandoff(active) &&
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

  String _rawMqttStatus(RealtimeEvent event) {
    final payload = event.payload;
    for (final value in <Object?>[
      payload?['status'],
      payload?['state'],
      payload?['type'],
      event.type,
    ]) {
      final normalized = value?.toString().trim();
      if (normalized != null && normalized.isNotEmpty) {
        return normalized;
      }
    }
    return 'unknown';
  }

  String _mqttEventRevision(RealtimeEvent event) {
    final payload = event.payload;
    final revision =
        payload?['revision'] ??
        payload?['snapshotVersion'] ??
        payload?['snapshot_version'];
    return revision?.toString() ?? 'none';
  }

  String _mqttTopicCategory(RealtimeEvent event) {
    final value = event.payload?['_mqttTopicCategory']?.toString().trim();
    return value == null || value.isEmpty ? 'unknown' : value;
  }

  bool _mqttUpdateRepresentsOpenState(
    MqttSosLifecycleUpdate update,
    String rawStatus,
  ) {
    final state = update.state;
    if (state != null && _isActiveLikeState(state)) {
      return true;
    }
    final normalized = rawStatus.trim().toLowerCase();
    return normalized == 'active' ||
        normalized == 'opened' ||
        normalized == 'processed' ||
        normalized == 'sent' ||
        normalized == 'triggerrequested' ||
        normalized == 'triggeredlocal';
  }

  String _normalizedMqttStatusLabel(
    MqttSosLifecycleUpdate update,
    String rawStatus,
  ) {
    final state = update.state;
    if (state != null) {
      return state.name;
    }
    final normalized = rawStatus.trim().toLowerCase();
    if (normalized == 'active' ||
        normalized == 'opened' ||
        normalized == 'processed' ||
        normalized == 'sent') {
      return SosState.sent.name;
    }
    return 'unknown';
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
    return snapshot.items
        .map((item) {
          final type = item.rawType.trim().isNotEmpty
              ? item.rawType.trim()
              : item.type.name;
          final status = item.rawStatus.trim().isNotEmpty
              ? item.rawStatus.trim()
              : item.status.name;
          final outcome = item.rawOutcome.trim().isNotEmpty
              ? item.rawOutcome.trim()
              : item.outcome.name;
          return '$type:$status:$outcome';
        })
        .join(',');
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
        incomingState == SosState.cancelRequested ||
        // A trigger stays `sending` until backend confirmation; a portal ACK
        // can be the first backend evidence (lost `processed`).
        incomingState == SosState.acknowledged) {
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
      reason:
          'invalid_state_machine_transition:$reason '
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
      return const <SosState>[SosState.idle, SosState.triggerRequested];
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
    final path = _liveTransitionPath(from: previousState, to: incomingState);
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
      return const <SosState>[SosState.cancelRequested, SosState.cancelled];
    }
    if (from == SosState.sending && to == SosState.acknowledged) {
      return const <SosState>[SosState.sent, SosState.acknowledged];
    }
    if (from == SosState.sending && to == SosState.cancelled) {
      return const <SosState>[SosState.cancelRequested, SosState.cancelled];
    }
    if (from == SosState.sending && to == SosState.resolved) {
      return const <SosState>[SosState.sent, SosState.resolved];
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
    if (incident.isBackendConfirmed) {
      return false;
    }
    // The backend not having it yet is expected while the outbox is still
    // delivering this SOS: never clear it to idle (it would look cancelled).
    if (_outbox.hasPendingTrigger) {
      return true;
    }
    if (incident.isUsingCachedData) {
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

  bool _isBackendActiveEvidenceState(SosState state) {
    return state == SosState.sent || state == SosState.acknowledged;
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

  bool _differentIdentity(String? left, String? right) {
    final normalizedLeft = _normalizeIdentity(left);
    final normalizedRight = _normalizeIdentity(right);
    return normalizedLeft != null &&
        normalizedRight != null &&
        normalizedLeft != normalizedRight;
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

class _PendingProcessedHandoff {
  const _PendingProcessedHandoff({
    required this.incidentId,
    required this.cycleKey,
    required this.occurredAt,
    required this.registeredAt,
  });

  final String? incidentId;
  final String? cycleKey;
  final DateTime occurredAt;
  final DateTime registeredAt;
}

class _PendingExternalRelayHandoff {
  const _PendingExternalRelayHandoff({
    required this.occurredAt,
    required this.registeredAt,
    required this.originatorNodeId,
    required this.relayNodeId,
    required this.deviceId,
    required this.hardwareId,
    required this.relayDeviceId,
    required this.relayHardwareId,
    required this.cycleKey,
    required this.source,
  });

  final DateTime occurredAt;
  final DateTime registeredAt;
  final int? originatorNodeId;
  final int? relayNodeId;
  final String? deviceId;
  final String? hardwareId;
  final String? relayDeviceId;
  final String? relayHardwareId;
  final String? cycleKey;
  final String source;
}

class _ExternalRelayLifecycleContext {
  const _ExternalRelayLifecycleContext({
    required this.incidentId,
    this.cycleKey,
    required this.occurredAt,
    required this.originatorNodeId,
    required this.relayNodeId,
    required this.relayHardwareId,
  });

  final String incidentId;
  final String? cycleKey;
  final DateTime occurredAt;
  final int? originatorNodeId;
  final int? relayNodeId;
  final String? relayHardwareId;
}

class _PersistedExternalRelayLifecycleContext {
  const _PersistedExternalRelayLifecycleContext({
    required this.sessionScope,
    required this.context,
  });

  static _PersistedExternalRelayLifecycleContext? tryParse(
    Map<String, dynamic>? json, {
    required DateTime now,
    required Duration ttl,
  }) {
    if (json == null) {
      return null;
    }
    final sessionScope = (json['sessionScope'] as String?)?.trim();
    final incidentId = (json['incidentId'] as String?)?.trim();
    final originatorNodeId = (json['originatorNodeId'] as num?)?.toInt();
    final relayNodeId = (json['relayNodeId'] as num?)?.toInt();
    final relayHardwareId = (json['relayHardwareId'] as String?)?.trim();
    final occurredAt = DateTime.tryParse(
      (json['occurredAt'] as String?) ?? '',
    )?.toUtc();
    final persistedAt = DateTime.tryParse(
      (json['persistedAt'] as String?) ?? '',
    )?.toUtc();
    if (sessionScope == null ||
        sessionScope.isEmpty ||
        incidentId == null ||
        incidentId.isEmpty ||
        originatorNodeId == null ||
        relayNodeId == null ||
        originatorNodeId == relayNodeId ||
        relayHardwareId == null ||
        relayHardwareId.isEmpty ||
        occurredAt == null ||
        persistedAt == null ||
        persistedAt.isAfter(now.add(const Duration(minutes: 5))) ||
        now.difference(persistedAt) > ttl) {
      return null;
    }
    return _PersistedExternalRelayLifecycleContext(
      sessionScope: sessionScope,
      context: _ExternalRelayLifecycleContext(
        incidentId: incidentId,
        cycleKey: json['cycleKey'] as String?,
        occurredAt: occurredAt,
        originatorNodeId: originatorNodeId,
        relayNodeId: relayNodeId,
        relayHardwareId: relayHardwareId,
      ),
    );
  }

  final String sessionScope;
  final _ExternalRelayLifecycleContext context;
}

class _LifecycleAuthorityDecision {
  const _LifecycleAuthorityDecision.accepted(this.reason) : accepted = true;
  const _LifecycleAuthorityDecision.rejected(this.reason) : accepted = false;

  final bool accepted;
  final String reason;
}
