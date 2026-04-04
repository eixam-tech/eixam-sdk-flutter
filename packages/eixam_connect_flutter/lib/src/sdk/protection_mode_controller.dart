import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';

import 'protection_platform_adapter.dart';

class ProtectionModeController {
  ProtectionModeController({
    required this.platformAdapter,
    required Future<EixamSession?> Function() sessionProvider,
    required Future<DeviceStatus> Function() deviceStatusProvider,
    required Future<PermissionState> Function() permissionStateProvider,
    required Future<SdkOperationalDiagnostics> Function()
        operationalDiagnosticsProvider,
  })  : _sessionProvider = sessionProvider,
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
  final Future<DeviceStatus> Function() _deviceStatusProvider;
  final Future<PermissionState> Function() _permissionStateProvider;
  final Future<SdkOperationalDiagnostics> Function()
      _operationalDiagnosticsProvider;

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

    final startResult = await platformAdapter.startProtectionRuntime();
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
      targetModeState: _shouldRunDegraded(armingSnapshot.status)
          ? ProtectionModeState.degraded
          : ProtectionModeState.armed,
      targetRuntimeState: startResult.runtimeState,
      targetCoverageLevel: _shouldRunDegraded(armingSnapshot.status)
          ? ProtectionCoverageLevel.partial
          : startResult.coverageLevel,
      options: options,
      degradationReason: _shouldRunDegraded(armingSnapshot.status)
          ? _deriveDegradedReason(armingSnapshot.status)
          : null,
    );
    _status = finalSnapshot.status;
    _diagnostics = finalSnapshot.diagnostics;
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
    final options = _activeOptions ?? const ProtectionModeOptions();
    final targetModeState = _activeOptions == null
        ? ProtectionModeState.off
        : _status.modeState == ProtectionModeState.armed
            ? ProtectionModeState.armed
            : _status.modeState == ProtectionModeState.degraded
                ? ProtectionModeState.degraded
                : ProtectionModeState.off;
    final targetRuntimeState = _activeOptions == null
        ? ProtectionRuntimeState.inactive
        : _status.runtimeState == ProtectionRuntimeState.failed
            ? ProtectionRuntimeState.failed
            : ProtectionRuntimeState.active;
    final targetCoverageLevel = _activeOptions == null
        ? ProtectionCoverageLevel.none
        : _status.coverageLevel;
    final snapshot = await _buildSnapshot(
      targetModeState: targetModeState,
      targetRuntimeState: targetRuntimeState,
      targetCoverageLevel: targetCoverageLevel,
      options: options,
      degradationReason:
          targetModeState == ProtectionModeState.degraded ? _status.degradationReason : null,
    );
    _status = snapshot.status;
    _diagnostics = snapshot.diagnostics;
    _emitStatus();
    _emitDiagnostics();
    return _status;
  }

  Future<FlushProtectionQueuesResult> flushQueues() async {
    final pendingSos = _status.pendingSosCount;
    final pendingTelemetry = _status.pendingTelemetryCount;
    _diagnostics = _diagnostics.copyWith(
      pendingSosCount: pendingSos,
      pendingTelemetryCount: pendingTelemetry,
    );
    _emitDiagnostics();
    return const FlushProtectionQueuesResult(
      flushedSosCount: 0,
      flushedTelemetryCount: 0,
      success: true,
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
  }) async {
    final session = await _sessionProvider();
    final deviceStatus = await _deviceStatusProvider();
    final permissionState = await _permissionStateProvider();
    final operationalDiagnostics = await _operationalDiagnosticsProvider();
    final platformSnapshot = await platformAdapter.getPlatformSnapshot();

    final sessionReady = session != null &&
        session.appId.trim().isNotEmpty &&
        session.externalUserId.trim().isNotEmpty &&
        session.userHash.trim().isNotEmpty;
    final bluetoothEnabled = permissionState.canUseBluetooth;
    final backendReachable = sessionReady;
    final realtimeReady = operationalDiagnostics.connectionState ==
            RealtimeConnectionState.connected &&
        operationalDiagnostics.sosEventTopics.isNotEmpty;
    final pendingSosCount =
        operationalDiagnostics.bridge.pendingSos == null ? 0 : 1;
    final pendingTelemetryCount =
        operationalDiagnostics.bridge.pendingTelemetry == null ? 0 : 1;

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
      if (!permissionState.hasNotificationAccess)
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
      notificationsPermissionGranted: permissionState.hasNotificationAccess,
      platformBackgroundCapabilityReady:
          platformSnapshot.backgroundCapabilityReady,
      backendReachable: backendReachable,
      realtimeReady: realtimeReady,
      storeAndForwardEnabled: options.enableStoreAndForward,
      pendingSosCount: pendingSosCount,
      pendingTelemetryCount: pendingTelemetryCount,
      activeDeviceId:
          deviceStatus.deviceId.trim().isEmpty ? null : deviceStatus.deviceId,
      degradationReason: degradationReason,
      updatedAt: DateTime.now().toUtc(),
    );
    final diagnostics = _diagnostics.copyWith(
      lastWakeAt: platformSnapshot.lastWakeAt,
      lastWakeReason: platformSnapshot.lastWakeReason,
      pendingSosCount: pendingSosCount,
      pendingTelemetryCount: pendingTelemetryCount,
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

  bool _shouldRunDegraded(ProtectionStatus status) {
    final options = _activeOptions ?? const ProtectionModeOptions();
    if (!options.allowDegradedMode) {
      return false;
    }
    return !status.deviceConnected || !status.realtimeReady;
  }

  String? _deriveDegradedReason(ProtectionStatus status) {
    if (!status.deviceConnected) {
      return 'Protection Mode is active, but the trusted device is not connected yet.';
    }
    if (!status.realtimeReady) {
      return 'Protection Mode is active, but realtime/backend connectivity is still recovering.';
    }
    return status.degradationReason;
  }

  void _handlePlatformEvent(ProtectionPlatformEvent event) {
    switch (event.type) {
      case ProtectionPlatformEventType.woke:
        _diagnostics = _diagnostics.copyWith(
          lastWakeAt: event.timestamp,
          lastWakeReason: event.reason,
        );
        _emitDiagnostics();
        break;
      case ProtectionPlatformEventType.runtimeStarted:
      case ProtectionPlatformEventType.runtimeRecovered:
        _diagnostics = _diagnostics.copyWith(
          lastWakeAt: event.timestamp,
          lastWakeReason: event.reason,
          lastFailureReason: null,
        );
        _emitDiagnostics();
        break;
      case ProtectionPlatformEventType.runtimeStopped:
        _diagnostics = _diagnostics.copyWith(
          lastWakeAt: event.timestamp,
          lastWakeReason: event.reason,
        );
        _emitDiagnostics();
        break;
      case ProtectionPlatformEventType.runtimeFailed:
        _diagnostics = _diagnostics.copyWith(
          lastFailureReason: event.reason,
        );
        _emitDiagnostics();
        break;
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
