import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'protection_platform_adapter.dart';

class ProtectionModeController {
  ProtectionModeController({
    required this.platformAdapter,
    required Future<EixamSession?> Function() sessionProvider,
    required EixamSdkConfig? Function() sdkConfigProvider,
    required Future<DeviceStatus> Function() deviceStatusProvider,
    required Future<PermissionState> Function() permissionStateProvider,
    required Future<SdkOperationalDiagnostics> Function()
        operationalDiagnosticsProvider,
    this.onBleOwnershipChanged,
  })  : _sessionProvider = sessionProvider,
        _sdkConfigProvider = sdkConfigProvider,
        _deviceStatusProvider = deviceStatusProvider,
        _permissionStateProvider = permissionStateProvider,
        _operationalDiagnosticsProvider = operationalDiagnosticsProvider {
    _platformEventsSub = platformAdapter.watchPlatformEvents().listen(
      _handlePlatformEvent,
      onError: (_) {
        _diagnostics = _diagnostics.copyWith(
          lastFailureReason: 'Protection platform event stream failed.',
        );
        _emitDiagnostics();
      },
    );
  }

  final ProtectionPlatformAdapter platformAdapter;
  final Future<EixamSession?> Function() _sessionProvider;
  final EixamSdkConfig? Function() _sdkConfigProvider;
  final Future<DeviceStatus> Function() _deviceStatusProvider;
  final Future<PermissionState> Function() _permissionStateProvider;
  final Future<SdkOperationalDiagnostics> Function()
      _operationalDiagnosticsProvider;
  final Future<void> Function(ProtectionBleOwner owner)? onBleOwnershipChanged;

  final StreamController<ProtectionStatus> _statusController =
      StreamController<ProtectionStatus>.broadcast();
  final StreamController<ProtectionDiagnostics> _diagnosticsController =
      StreamController<ProtectionDiagnostics>.broadcast();

  StreamSubscription<ProtectionPlatformEvent>? _platformEventsSub;
  ProtectionModeOptions? _activeOptions;
  ProtectionStatus _status = ProtectionStatus(
    modeState: ProtectionModeState.off,
    coverageLevel: ProtectionCoverageLevel.none,
    runtimeState: ProtectionRuntimeState.inactive,
    sessionReady: false,
    devicePaired: false,
    deviceConnected: false,
    bluetoothEnabled: false,
    locationPermissionGranted: false,
    notificationsPermissionGranted: false,
    platformBackgroundCapabilityReady: false,
    backendReachable: false,
    realtimeReady: false,
    storeAndForwardEnabled: false,
    pendingSosCount: 0,
    pendingTelemetryCount: 0,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
  ProtectionDiagnostics _diagnostics = const ProtectionDiagnostics(
    pendingSosCount: 0,
    pendingTelemetryCount: 0,
  );

  ProtectionStatus get currentStatus => _status;

  Future<ProtectionReadinessReport> evaluateReadiness({
    ProtectionModeOptions options = const ProtectionModeOptions(),
  }) async {
    final snapshot = await _buildSnapshot(
      targetModeState: ProtectionModeState.off,
      targetRuntimeState: ProtectionRuntimeState.inactive,
      targetCoverageLevel: ProtectionCoverageLevel.none,
      options: options,
    );
    _status = snapshot.status;
    _diagnostics = snapshot.diagnostics;
    _emitStatus();
    _emitDiagnostics();
    return snapshot.readinessReport;
  }

  Future<EnterProtectionModeResult> enter({
    ProtectionModeOptions options = const ProtectionModeOptions(),
  }) async {
    _activeOptions = options;
    final armingSnapshot = await _buildSnapshot(
      targetModeState: ProtectionModeState.arming,
      targetRuntimeState: ProtectionRuntimeState.starting,
      targetCoverageLevel: ProtectionCoverageLevel.none,
      options: options,
    );
    _status = armingSnapshot.status;
    _diagnostics = armingSnapshot.diagnostics.copyWith(
      lastWakeAt: DateTime.now().toUtc(),
      lastWakeReason: 'enter_protection_mode',
    );
    _emitStatus();
    _emitDiagnostics();

    final blockingIssues = <ProtectionBlockingIssue>[
      ...armingSnapshot.readinessReport.blockingIssues,
    ];

    if (blockingIssues.isNotEmpty) {
      _status = armingSnapshot.status.copyWith(
        modeState: ProtectionModeState.off,
        runtimeState: ProtectionRuntimeState.inactive,
        coverageLevel: ProtectionCoverageLevel.none,
        degradationReason: blockingIssues.first.message,
        updatedAt: DateTime.now().toUtc(),
      );
      _emitStatus();
      return EnterProtectionModeResult(
        success: false,
        status: _status,
        blockingIssues: blockingIssues,
      );
    }

    final startRequest = ProtectionPlatformStartRequest(
      modeOptions: options,
      activeDeviceId: armingSnapshot.status.activeDeviceId,
      apiBaseUrl: _sdkConfigProvider()?.apiBaseUrl,
      sessionReady: armingSnapshot.status.sessionReady,
      enableStoreAndForward: options.enableStoreAndForward,
    );
    final startResult = await platformAdapter.startProtectionRuntime(
      request: startRequest,
    );
    if (!startResult.success) {
      final failureReason = startResult.failureReason ??
          'Protection runtime could not be started in this host app.';
      final issue = ProtectionBlockingIssue(
        type: ProtectionBlockingIssueType.hostRuntimeStartFailed,
        message: failureReason,
        canBeResolvedInline: false,
      );
      _diagnostics = _diagnostics.copyWith(lastFailureReason: failureReason);
      _status = armingSnapshot.status.copyWith(
        modeState: ProtectionModeState.error,
        runtimeState: ProtectionRuntimeState.failed,
        coverageLevel: ProtectionCoverageLevel.none,
        degradationReason: failureReason,
        updatedAt: DateTime.now().toUtc(),
      );
      _emitDiagnostics();
      _emitStatus();
      return EnterProtectionModeResult(
        success: false,
        status: _status,
        blockingIssues: <ProtectionBlockingIssue>[issue],
      );
    }

    final finalSnapshot = await _buildSnapshot(
      targetModeState: _shouldRunDegraded(
        armingSnapshot.status,
        platformCoverageLevel: startResult.coverageLevel,
      )
          ? ProtectionModeState.degraded
          : ProtectionModeState.armed,
      targetRuntimeState: startResult.runtimeState,
      targetCoverageLevel: _shouldRunDegraded(
        armingSnapshot.status,
        platformCoverageLevel: startResult.coverageLevel,
      )
          ? ProtectionCoverageLevel.partial
          : startResult.coverageLevel,
      options: options,
      degradationReason: _shouldRunDegraded(
        armingSnapshot.status,
        platformCoverageLevel: startResult.coverageLevel,
      )
          ? _deriveDegradedReason(
              armingSnapshot.status,
              platformCoverageLevel: startResult.coverageLevel,
              platformStatusMessage: startResult.statusMessage,
            )
          : null,
    );
    _status = finalSnapshot.status;
    _diagnostics = finalSnapshot.diagnostics;
    await onBleOwnershipChanged?.call(_status.bleOwner);
    _emitStatus();
    _emitDiagnostics();
    return EnterProtectionModeResult(
      success: true,
      status: _status,
      blockingIssues: const <ProtectionBlockingIssue>[],
    );
  }

  Future<ProtectionStatus> exit() async {
    _status = _status.copyWith(
      modeState: ProtectionModeState.stopping,
      runtimeState: ProtectionRuntimeState.inactive,
      updatedAt: DateTime.now().toUtc(),
    );
    _emitStatus();
    await platformAdapter.stopProtectionRuntime();
    _activeOptions = null;
    final snapshot = await _buildSnapshot(
      targetModeState: ProtectionModeState.off,
      targetRuntimeState: ProtectionRuntimeState.inactive,
      targetCoverageLevel: ProtectionCoverageLevel.none,
      options: const ProtectionModeOptions(),
    );
    _status = snapshot.status.copyWith(
      storeAndForwardEnabled: false,
      degradationReason: null,
      updatedAt: DateTime.now().toUtc(),
    );
    _diagnostics = snapshot.diagnostics;
    await onBleOwnershipChanged?.call(_status.bleOwner);
    _emitStatus();
    _emitDiagnostics();
    return _status;
  }

  Future<ProtectionStatus> getStatus() async => _status;

  Stream<ProtectionStatus> watchStatus() async* {
    yield _status;
    yield* _statusController.stream;
  }

  Future<ProtectionDiagnostics> getDiagnostics() async => _diagnostics;

  Stream<ProtectionDiagnostics> watchDiagnostics() async* {
    yield _diagnostics;
    yield* _diagnosticsController.stream;
  }

  Future<ProtectionStatus> rehydrate() async {
    final platformSnapshot = await platformAdapter.getPlatformSnapshot();
    final hasRecoveredRuntime = platformSnapshot.runtimeActive ||
        platformSnapshot.serviceRunning ||
        platformSnapshot.runtimeState == ProtectionRuntimeState.active ||
        platformSnapshot.runtimeState == ProtectionRuntimeState.recovering;
    if (_activeOptions == null && hasRecoveredRuntime) {
      _activeOptions = const ProtectionModeOptions();
    }

    final options = _activeOptions ?? const ProtectionModeOptions();
    final targetModeState = _activeOptions == null
        ? ProtectionModeState.off
        : platformSnapshot.coverageLevel == ProtectionCoverageLevel.partial ||
                _status.modeState == ProtectionModeState.degraded
            ? ProtectionModeState.degraded
            : ProtectionModeState.armed;
    final targetRuntimeState = _activeOptions == null
        ? ProtectionRuntimeState.inactive
        : platformSnapshot.runtimeState == ProtectionRuntimeState.inactive
            ? (_status.runtimeState == ProtectionRuntimeState.failed
                ? ProtectionRuntimeState.failed
                : ProtectionRuntimeState.active)
            : platformSnapshot.runtimeState;
    final targetCoverageLevel = _activeOptions == null
        ? ProtectionCoverageLevel.none
        : platformSnapshot.coverageLevel == ProtectionCoverageLevel.none
            ? _status.coverageLevel
            : platformSnapshot.coverageLevel;
    final snapshot = await _buildSnapshot(
      targetModeState: targetModeState,
      targetRuntimeState: targetRuntimeState,
      targetCoverageLevel: targetCoverageLevel,
      options: options,
      degradationReason: targetModeState == ProtectionModeState.degraded
          ? _status.degradationReason ??
              platformSnapshot.lastFailureReason ??
              'Protection runtime was rehydrated with partial platform coverage.'
          : null,
      platformSnapshotOverride: platformSnapshot,
    );
    _status = snapshot.status;
    _diagnostics = snapshot.diagnostics;
    await onBleOwnershipChanged?.call(_status.bleOwner);
    _emitStatus();
    _emitDiagnostics();
    return _status;
  }

  Future<FlushProtectionQueuesResult> flushQueues() async {
    final platformFlushResult = await platformAdapter.flushProtectionQueues();
    final pendingSos = _status.pendingSosCount;
    final pendingTelemetry = _status.pendingTelemetryCount;
    _diagnostics = _diagnostics.copyWith(
      pendingSosCount: pendingSos - platformFlushResult.flushedSosCount < 0
          ? 0
          : pendingSos - platformFlushResult.flushedSosCount,
      pendingTelemetryCount:
          pendingTelemetry - platformFlushResult.flushedTelemetryCount < 0
              ? 0
              : pendingTelemetry - platformFlushResult.flushedTelemetryCount,
    );
    _status = _status.copyWith(
      pendingSosCount: _diagnostics.pendingSosCount,
      pendingTelemetryCount: _diagnostics.pendingTelemetryCount,
      updatedAt: DateTime.now().toUtc(),
    );
    _emitStatus();
    _emitDiagnostics();
    return FlushProtectionQueuesResult(
      flushedSosCount: platformFlushResult.flushedSosCount,
      flushedTelemetryCount: platformFlushResult.flushedTelemetryCount,
      success: platformFlushResult.success,
    );
  }

  Future<void> dispose() async {
    await _platformEventsSub?.cancel();
    await _statusController.close();
    await _diagnosticsController.close();
  }

  Future<_ProtectionSnapshot> _buildSnapshot({
    required ProtectionModeState targetModeState,
    required ProtectionRuntimeState targetRuntimeState,
    required ProtectionCoverageLevel targetCoverageLevel,
    required ProtectionModeOptions options,
    String? degradationReason,
    ProtectionPlatformSnapshot? platformSnapshotOverride,
  }) async {
    final session = await _sessionProvider();
    final deviceStatus = await _deviceStatusProvider();
    final permissionState = await _permissionStateProvider();
    final operationalDiagnostics = await _operationalDiagnosticsProvider();
    final platformSnapshot =
        platformSnapshotOverride ?? await platformAdapter.getPlatformSnapshot();

    final sessionReady = session != null &&
        session.appId.trim().isNotEmpty &&
        session.externalUserId.trim().isNotEmpty &&
        session.userHash.trim().isNotEmpty;
    final bluetoothEnabled =
        platformSnapshot.bluetoothEnabled ?? permissionState.canUseBluetooth;
    final notificationsGranted = platformSnapshot.notificationsGranted ??
        permissionState.hasNotificationAccess;
    final backendReachable = sessionReady;
    final realtimeReady = operationalDiagnostics.connectionState ==
            RealtimeConnectionState.connected &&
        operationalDiagnostics.sosEventTopics.isNotEmpty;
    final pendingSosCount = [
      operationalDiagnostics.bridge.pendingSos == null ? 0 : 1,
      platformSnapshot.pendingSosCount
    ].reduce((a, b) => a > b ? a : b);
    final pendingTelemetryCount = [
      operationalDiagnostics.bridge.pendingTelemetry == null ? 0 : 1,
      platformSnapshot.pendingTelemetryCount,
    ].reduce((a, b) => a > b ? a : b);

    final blockingIssues = <ProtectionBlockingIssue>[
      if (!sessionReady)
        const ProtectionBlockingIssue(
          type: ProtectionBlockingIssueType.noSession,
          message:
              'A signed SDK session is required before Protection Mode can be enabled.',
          canBeResolvedInline: false,
        ),
      if (!deviceStatus.paired)
        const ProtectionBlockingIssue(
          type: ProtectionBlockingIssueType.noPairedDevice,
          message:
              'Pair a trusted EIXAM device before enabling Protection Mode.',
          canBeResolvedInline: true,
        ),
      if (!bluetoothEnabled)
        const ProtectionBlockingIssue(
          type: ProtectionBlockingIssueType.bluetoothDisabled,
          message:
              'Bluetooth access and adapter availability are required for Protection Mode.',
          canBeResolvedInline: true,
        ),
      if (!permissionState.hasLocationAccess)
        const ProtectionBlockingIssue(
          type: ProtectionBlockingIssueType.locationPermissionMissing,
          message:
              'Location permission is required before Protection Mode can be enabled.',
          canBeResolvedInline: true,
        ),
      if (!notificationsGranted)
        const ProtectionBlockingIssue(
          type: ProtectionBlockingIssueType.notificationsPermissionMissing,
          message:
              'Notification permission is required so Protection Mode can surface runtime issues.',
          canBeResolvedInline: true,
        ),
      if (!platformSnapshot.backgroundCapabilityReady)
        const ProtectionBlockingIssue(
          type: ProtectionBlockingIssueType.platformBackgroundCapabilityMissing,
          message:
              'Host platform background runtime support is not configured yet for Protection Mode.',
          canBeResolvedInline: false,
        ),
    ];

    final warnings = <String>[
      if (!deviceStatus.connected)
        'The trusted device is not connected right now. Protection Mode would start in reconnect/recovery posture.',
      if (!realtimeReady)
        'Realtime/backend transport is not fully ready, so Protection Mode would rely on reconnect or store-and-forward behavior.',
      if (!options.enableStoreAndForward)
        'Store-and-forward is disabled for this Protection Mode configuration.',
    ];

    final status = ProtectionStatus(
      modeState: targetModeState,
      coverageLevel: targetCoverageLevel,
      runtimeState: targetRuntimeState,
      sessionReady: sessionReady,
      devicePaired: deviceStatus.paired,
      deviceConnected: deviceStatus.connected,
      bluetoothEnabled: bluetoothEnabled,
      locationPermissionGranted: permissionState.hasLocationAccess,
      notificationsPermissionGranted: notificationsGranted,
      platformBackgroundCapabilityReady:
          platformSnapshot.backgroundCapabilityReady,
      backendReachable: backendReachable,
      realtimeReady: realtimeReady,
      storeAndForwardEnabled: options.enableStoreAndForward,
      pendingSosCount: pendingSosCount,
      pendingTelemetryCount: pendingTelemetryCount,
      pendingNativeSosCreateCount:
          platformSnapshot.pendingNativeSosCreateCount,
      pendingNativeSosCancelCount:
          platformSnapshot.pendingNativeSosCancelCount,
      platformRuntimeConfigured: platformSnapshot.platformRuntimeConfigured,
      foregroundServiceRunning: platformSnapshot.serviceRunning,
      protectionRuntimeActive: platformSnapshot.runtimeActive,
      platform: platformSnapshot.platform,
      bleOwner: platformSnapshot.bleOwner,
      backgroundCapabilityState: platformSnapshot.backgroundCapabilityState,
      restorationConfigured: platformSnapshot.restorationConfigured,
      serviceBleConnected: platformSnapshot.serviceBleConnected,
      serviceBleReady: platformSnapshot.serviceBleReady,
      lastPlatformEvent: platformSnapshot.lastPlatformEvent,
      lastPlatformEventAt: platformSnapshot.lastPlatformEventAt,
      lastRestorationEvent: platformSnapshot.lastRestorationEvent,
      lastRestorationEventAt: platformSnapshot.lastRestorationEventAt,
      lastBleServiceEvent: platformSnapshot.lastBleServiceEvent,
      lastBleServiceEventAt: platformSnapshot.lastBleServiceEventAt,
      reconnectAttemptCount: platformSnapshot.reconnectAttemptCount,
      lastReconnectAttemptAt: platformSnapshot.lastReconnectAttemptAt,
      lastNativeBackendHandoffResult:
          platformSnapshot.lastNativeBackendHandoffResult,
      lastNativeBackendHandoffError:
          platformSnapshot.lastNativeBackendHandoffError,
      activeDeviceId:
          deviceStatus.deviceId.trim().isEmpty ? null : deviceStatus.deviceId,
      degradationReason:
          degradationReason ?? platformSnapshot.degradationReason,
      updatedAt: DateTime.now().toUtc(),
    );
    final diagnostics = _diagnostics.copyWith(
      lastWakeAt: platformSnapshot.lastWakeAt,
      lastWakeReason: platformSnapshot.lastWakeReason,
      lastFailureReason:
          platformSnapshot.lastFailureReason ?? _diagnostics.lastFailureReason,
      lastPlatformEvent:
          platformSnapshot.lastPlatformEvent ?? _diagnostics.lastPlatformEvent,
      lastPlatformEventAt: platformSnapshot.lastPlatformEventAt ??
          _diagnostics.lastPlatformEventAt,
      lastRestorationEvent: platformSnapshot.lastRestorationEvent ??
          _diagnostics.lastRestorationEvent,
      lastRestorationEventAt: platformSnapshot.lastRestorationEventAt ??
          _diagnostics.lastRestorationEventAt,
      lastBleServiceEvent: platformSnapshot.lastBleServiceEvent ??
          _diagnostics.lastBleServiceEvent,
      lastBleServiceEventAt: platformSnapshot.lastBleServiceEventAt ??
          _diagnostics.lastBleServiceEventAt,
      reconnectAttemptCount: platformSnapshot.reconnectAttemptCount,
      lastReconnectAttemptAt: platformSnapshot.lastReconnectAttemptAt ??
          _diagnostics.lastReconnectAttemptAt,
      pendingSosCount: pendingSosCount,
      pendingTelemetryCount: pendingTelemetryCount,
      pendingNativeSosCreateCount:
          platformSnapshot.pendingNativeSosCreateCount,
      pendingNativeSosCancelCount:
          platformSnapshot.pendingNativeSosCancelCount,
      lastNativeBackendHandoffResult:
          platformSnapshot.lastNativeBackendHandoffResult,
      lastNativeBackendHandoffError:
          platformSnapshot.lastNativeBackendHandoffError,
    );
    return _ProtectionSnapshot(
      status: status,
      diagnostics: diagnostics,
      readinessReport: ProtectionReadinessReport(
        canArm: blockingIssues.isEmpty,
        blockingIssues: blockingIssues,
        warnings: warnings,
      ),
    );
  }

  bool _shouldRunDegraded(
    ProtectionStatus status, {
    ProtectionCoverageLevel? platformCoverageLevel,
  }) {
    final options = _activeOptions ?? const ProtectionModeOptions();
    if (!options.allowDegradedMode) {
      return false;
    }
    return !status.deviceConnected ||
        !status.realtimeReady ||
        platformCoverageLevel == ProtectionCoverageLevel.partial;
  }

  String? _deriveDegradedReason(
    ProtectionStatus status, {
    ProtectionCoverageLevel? platformCoverageLevel,
    String? platformStatusMessage,
  }) {
    if ((platformStatusMessage ?? '').trim().isNotEmpty &&
        platformCoverageLevel == ProtectionCoverageLevel.partial) {
      return platformStatusMessage;
    }
    if (!status.deviceConnected) {
      return 'Protection Mode is active, but the trusted device is not connected yet.';
    }
    if (!status.realtimeReady) {
      return 'Protection Mode is active, but realtime/backend connectivity is still recovering.';
    }
    return status.degradationReason;
  }

  void _handlePlatformEvent(ProtectionPlatformEvent event) {
    _diagnostics = _diagnostics.copyWith(
      lastPlatformEvent: event.type.name,
      lastPlatformEventAt: event.timestamp,
    );
    switch (event.type) {
      case ProtectionPlatformEventType.woke:
        _diagnostics = _diagnostics.copyWith(
          lastWakeAt: event.timestamp,
          lastWakeReason: event.reason,
        );
        _emitDiagnostics();
        break;
      case ProtectionPlatformEventType.serviceStarted:
      case ProtectionPlatformEventType.serviceRestarted:
        _status = _status.copyWith(
          foregroundServiceRunning: true,
          bleOwner: ProtectionBleOwner.androidService,
          lastPlatformEvent: event.type.name,
          lastPlatformEventAt: event.timestamp,
          updatedAt: event.timestamp,
        );
        _emitStatus();
        _emitDiagnostics();
        break;
      case ProtectionPlatformEventType.runtimeStarting:
        _status = _status.copyWith(
          foregroundServiceRunning: true,
          protectionRuntimeActive: true,
          runtimeState: ProtectionRuntimeState.starting,
          bleOwner: ProtectionBleOwner.androidService,
          lastPlatformEvent: event.type.name,
          lastPlatformEventAt: event.timestamp,
          updatedAt: event.timestamp,
        );
        _emitStatus();
        _emitDiagnostics();
        break;
      case ProtectionPlatformEventType.runtimeStarted:
      case ProtectionPlatformEventType.runtimeActive:
      case ProtectionPlatformEventType.runtimeRecovered:
      case ProtectionPlatformEventType.runtimeRestarted:
        _diagnostics = _diagnostics.copyWith(
          lastWakeAt: event.timestamp,
          lastWakeReason: event.reason,
          lastFailureReason: null,
        );
        _status = _status.copyWith(
          foregroundServiceRunning: true,
          protectionRuntimeActive: true,
          bleOwner: ProtectionBleOwner.androidService,
          runtimeState:
              event.type == ProtectionPlatformEventType.runtimeRecovered
                  ? ProtectionRuntimeState.recovering
                  : ProtectionRuntimeState.active,
          lastPlatformEvent: event.type.name,
          lastPlatformEventAt: event.timestamp,
          updatedAt: event.timestamp,
        );
        _emitStatus();
        _emitDiagnostics();
        break;
      case ProtectionPlatformEventType.deviceConnecting:
        _status = _status.copyWith(
          bleOwner: ProtectionBleOwner.androidService,
          serviceBleConnected: false,
          serviceBleReady: false,
          lastBleServiceEvent: event.type.name,
          lastBleServiceEventAt: event.timestamp,
          updatedAt: event.timestamp,
        );
        _emitStatus();
        _emitDiagnostics();
        break;
      case ProtectionPlatformEventType.restorationDetected:
      case ProtectionPlatformEventType.restorationRehydrated:
        _status = _status.copyWith(
          lastRestorationEvent: event.type.name,
          lastRestorationEventAt: event.timestamp,
          lastPlatformEvent: event.type.name,
          lastPlatformEventAt: event.timestamp,
          updatedAt: event.timestamp,
        );
        _diagnostics = _diagnostics.copyWith(
          lastRestorationEvent: event.type.name,
          lastRestorationEventAt: event.timestamp,
          lastPlatformEvent: event.type.name,
          lastPlatformEventAt: event.timestamp,
        );
        _emitStatus();
        _emitDiagnostics();
        break;
      case ProtectionPlatformEventType.nativeBackendSyncQueued:
      case ProtectionPlatformEventType.nativeBackendSyncSucceeded:
      case ProtectionPlatformEventType.nativeBackendSyncFailed:
        final result = event.type == ProtectionPlatformEventType.nativeBackendSyncSucceeded
            ? event.reason
            : _status.lastNativeBackendHandoffResult;
        final error = event.type == ProtectionPlatformEventType.nativeBackendSyncFailed
            ? event.reason
            : _status.lastNativeBackendHandoffError;
        _status = _status.copyWith(
          lastPlatformEvent: event.type.name,
          lastPlatformEventAt: event.timestamp,
          lastNativeBackendHandoffResult: result,
          lastNativeBackendHandoffError: error,
          updatedAt: event.timestamp,
        );
        _diagnostics = _diagnostics.copyWith(
          lastBackendSyncAt: event.timestamp,
          lastPlatformEvent: event.type.name,
          lastPlatformEventAt: event.timestamp,
          lastNativeBackendHandoffResult: result,
          lastNativeBackendHandoffError: error,
        );
        _emitStatus();
        _emitDiagnostics();
        break;
      case ProtectionPlatformEventType.deviceConnected:
        _status = _status.copyWith(
          bleOwner: ProtectionBleOwner.androidService,
          serviceBleConnected: true,
          lastBleServiceEvent: event.type.name,
          lastBleServiceEventAt: event.timestamp,
          updatedAt: event.timestamp,
        );
        _emitStatus();
        _emitDiagnostics();
        break;
      case ProtectionPlatformEventType.servicesDiscovered:
      case ProtectionPlatformEventType.subscriptionsActive:
      case ProtectionPlatformEventType.packetReceived:
      case ProtectionPlatformEventType.sosEventReceived:
        _status = _status.copyWith(
          bleOwner: ProtectionBleOwner.androidService,
          serviceBleReady:
              event.type == ProtectionPlatformEventType.subscriptionsActive
                  ? true
                  : _status.serviceBleReady,
          lastBleServiceEvent: event.type.name,
          lastBleServiceEventAt: event.timestamp,
          updatedAt: event.timestamp,
        );
        _diagnostics = _diagnostics.copyWith(
          lastBleServiceEvent: event.type.name,
          lastBleServiceEventAt: event.timestamp,
        );
        _emitStatus();
        _emitDiagnostics();
        break;
      case ProtectionPlatformEventType.deviceDisconnected:
        _status = _status.copyWith(
          serviceBleConnected: false,
          serviceBleReady: false,
          lastBleServiceEvent: event.type.name,
          lastBleServiceEventAt: event.timestamp,
          updatedAt: event.timestamp,
        );
        _diagnostics = _diagnostics.copyWith(
          lastBleServiceEvent: event.type.name,
          lastBleServiceEventAt: event.timestamp,
        );
        _emitStatus();
        _emitDiagnostics();
        break;
      case ProtectionPlatformEventType.reconnectScheduled:
      case ProtectionPlatformEventType.reconnectFailed:
        final nextReconnectAttemptCount = _status.reconnectAttemptCount + 1;
        _status = _status.copyWith(
          reconnectAttemptCount: nextReconnectAttemptCount,
          lastReconnectAttemptAt: event.timestamp,
          lastBleServiceEvent: event.type.name,
          lastBleServiceEventAt: event.timestamp,
          updatedAt: event.timestamp,
        );
        _diagnostics = _diagnostics.copyWith(
          reconnectAttemptCount: nextReconnectAttemptCount,
          lastReconnectAttemptAt: event.timestamp,
          lastBleServiceEvent: event.type.name,
          lastBleServiceEventAt: event.timestamp,
        );
        _emitStatus();
        _emitDiagnostics();
        break;
      case ProtectionPlatformEventType.runtimeStopped:
      case ProtectionPlatformEventType.serviceStopped:
        _diagnostics = _diagnostics.copyWith(
          lastWakeAt: event.timestamp,
          lastWakeReason: event.reason,
        );
        _status = _status.copyWith(
          foregroundServiceRunning: false,
          protectionRuntimeActive: false,
          bleOwner: ProtectionBleOwner.flutter,
          serviceBleConnected: false,
          serviceBleReady: false,
          runtimeState: ProtectionRuntimeState.inactive,
          lastPlatformEvent: event.type.name,
          lastPlatformEventAt: event.timestamp,
          updatedAt: event.timestamp,
        );
        _emitStatus();
        _emitDiagnostics();
        break;
      case ProtectionPlatformEventType.runtimeFailed:
      case ProtectionPlatformEventType.runtimeError:
        _diagnostics = _diagnostics.copyWith(
          lastFailureReason: event.reason,
          lastPlatformEvent: event.type.name,
          lastPlatformEventAt: event.timestamp,
        );
        _status = _status.copyWith(
          runtimeState: ProtectionRuntimeState.failed,
          lastPlatformEvent: event.type.name,
          lastPlatformEventAt: event.timestamp,
          updatedAt: event.timestamp,
        );
        _emitStatus();
        _emitDiagnostics();
        break;
      case ProtectionPlatformEventType.bluetoothTurnedOff:
      case ProtectionPlatformEventType.bluetoothTurnedOn:
        _status = _status.copyWith(
          bluetoothEnabled:
              event.type == ProtectionPlatformEventType.bluetoothTurnedOn,
          updatedAt: event.timestamp,
        );
        _emitStatus();
        _emitDiagnostics();
        break;
    }

    final shouldRehydrate = _activeOptions != null &&
        (event.type == ProtectionPlatformEventType.woke ||
            event.type == ProtectionPlatformEventType.runtimeStarted ||
            event.type == ProtectionPlatformEventType.runtimeActive ||
            event.type == ProtectionPlatformEventType.runtimeRecovered ||
            event.type == ProtectionPlatformEventType.runtimeRestarted ||
            event.type == ProtectionPlatformEventType.nativeBackendSyncQueued ||
            event.type == ProtectionPlatformEventType.nativeBackendSyncSucceeded ||
            event.type == ProtectionPlatformEventType.nativeBackendSyncFailed ||
            event.type == ProtectionPlatformEventType.bluetoothTurnedOff ||
            event.type == ProtectionPlatformEventType.bluetoothTurnedOn);
    if (shouldRehydrate) {
      unawaited(rehydrate());
    }
  }

  void _emitStatus() {
    if (!_statusController.isClosed) {
      _statusController.add(_status);
    }
  }

  void _emitDiagnostics() {
    if (!_diagnosticsController.isClosed) {
      _diagnosticsController.add(_diagnostics);
    }
  }
}

class _ProtectionSnapshot {
  const _ProtectionSnapshot({
    required this.status,
    required this.diagnostics,
    required this.readinessReport,
  });

  final ProtectionStatus status;
  final ProtectionDiagnostics diagnostics;
  final ProtectionReadinessReport readinessReport;
}
