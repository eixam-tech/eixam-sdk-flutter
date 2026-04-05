import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

enum ProtectionPlatformEventType {
  serviceStarted,
  serviceStopped,
  serviceRestarted,
  woke,
  runtimeStarting,
  runtimeStarted,
  runtimeActive,
  runtimeStopped,
  runtimeRecovered,
  runtimeRestarted,
  runtimeFailed,
  deviceConnecting,
  deviceConnected,
  deviceDisconnected,
  reconnectScheduled,
  reconnectFailed,
  servicesDiscovered,
  subscriptionsActive,
  sosEventReceived,
  runtimeError,
  bluetoothTurnedOff,
  bluetoothTurnedOn,
}

class ProtectionPlatformStartRequest {
  const ProtectionPlatformStartRequest({
    required this.modeOptions,
    this.activeDeviceId,
    this.sessionReady = false,
    this.enableStoreAndForward = true,
  });

  final ProtectionModeOptions modeOptions;
  final String? activeDeviceId;
  final bool sessionReady;
  final bool enableStoreAndForward;
}

class ProtectionPlatformFlushResult {
  const ProtectionPlatformFlushResult({
    this.flushedSosCount = 0,
    this.flushedTelemetryCount = 0,
    this.success = true,
  });

  final int flushedSosCount;
  final int flushedTelemetryCount;
  final bool success;
}

class ProtectionPlatformSnapshot {
  const ProtectionPlatformSnapshot({
    required this.backgroundCapabilityReady,
    this.platformRuntimeConfigured = false,
    this.foregroundServiceConfigured = false,
    this.serviceRunning = false,
    this.runtimeActive = false,
    this.bluetoothEnabled,
    this.notificationsGranted,
    this.lastFailureReason,
    this.lastPlatformEvent,
    this.lastPlatformEventAt,
    this.runtimeState = ProtectionRuntimeState.inactive,
    this.coverageLevel = ProtectionCoverageLevel.none,
    this.lastWakeAt,
    this.lastWakeReason,
    this.platform = ProtectionPlatform.unknown,
    this.backgroundCapabilityState = ProtectionCapabilityState.unknown,
    this.bleOwner = ProtectionBleOwner.flutter,
    this.serviceBleConnected = false,
    this.serviceBleReady = false,
    this.lastBleServiceEvent,
    this.lastBleServiceEventAt,
    this.reconnectAttemptCount = 0,
    this.lastReconnectAttemptAt,
    this.degradationReason,
  });

  final bool backgroundCapabilityReady;
  final bool platformRuntimeConfigured;
  final bool foregroundServiceConfigured;
  final bool serviceRunning;
  final bool runtimeActive;
  final bool? bluetoothEnabled;
  final bool? notificationsGranted;
  final String? lastFailureReason;
  final String? lastPlatformEvent;
  final DateTime? lastPlatformEventAt;
  final ProtectionRuntimeState runtimeState;
  final ProtectionCoverageLevel coverageLevel;
  final DateTime? lastWakeAt;
  final String? lastWakeReason;
  final ProtectionPlatform platform;
  final ProtectionCapabilityState backgroundCapabilityState;
  final ProtectionBleOwner bleOwner;
  final bool serviceBleConnected;
  final bool serviceBleReady;
  final String? lastBleServiceEvent;
  final DateTime? lastBleServiceEventAt;
  final int reconnectAttemptCount;
  final DateTime? lastReconnectAttemptAt;
  final String? degradationReason;
}

class ProtectionPlatformStartResult {
  const ProtectionPlatformStartResult({
    required this.success,
    this.runtimeState = ProtectionRuntimeState.active,
    this.coverageLevel = ProtectionCoverageLevel.full,
    this.failureReason,
    this.statusMessage,
  });

  final bool success;
  final ProtectionRuntimeState runtimeState;
  final ProtectionCoverageLevel coverageLevel;
  final String? failureReason;
  final String? statusMessage;
}

class ProtectionPermissionResult {
  const ProtectionPermissionResult({
    required this.locationGranted,
    required this.notificationsGranted,
    required this.bluetoothGranted,
  });

  final bool locationGranted;
  final bool notificationsGranted;
  final bool bluetoothGranted;
}

class ProtectionPlatformEvent {
  const ProtectionPlatformEvent({
    required this.type,
    required this.timestamp,
    this.reason,
  });

  final ProtectionPlatformEventType type;
  final DateTime timestamp;
  final String? reason;
}

abstract class ProtectionPlatformAdapter {
  Future<ProtectionPlatformSnapshot> getPlatformSnapshot();
  Future<ProtectionPlatformStartResult> startProtectionRuntime({
    required ProtectionPlatformStartRequest request,
  });
  Future<void> stopProtectionRuntime();
  Future<ProtectionPlatformFlushResult> flushProtectionQueues();
  Future<ProtectionPermissionResult> requestProtectionPermissions();
  Future<void> openProtectionSettings();
  Stream<ProtectionPlatformEvent> watchPlatformEvents();
}

class NoopProtectionPlatformAdapter implements ProtectionPlatformAdapter {
  const NoopProtectionPlatformAdapter();

  @override
  Future<ProtectionPlatformSnapshot> getPlatformSnapshot() async {
    return const ProtectionPlatformSnapshot(
      backgroundCapabilityReady: false,
    );
  }

  @override
  Future<ProtectionPlatformStartResult> startProtectionRuntime({
    required ProtectionPlatformStartRequest request,
  }) async {
    return const ProtectionPlatformStartResult(
      success: false,
      runtimeState: ProtectionRuntimeState.failed,
      coverageLevel: ProtectionCoverageLevel.none,
      failureReason:
          'Protection Mode platform runtime is not configured in this host app yet.',
    );
  }

  @override
  Future<void> stopProtectionRuntime() async {}

  @override
  Future<ProtectionPlatformFlushResult> flushProtectionQueues() async {
    return const ProtectionPlatformFlushResult();
  }

  @override
  Future<ProtectionPermissionResult> requestProtectionPermissions() async {
    return const ProtectionPermissionResult(
      locationGranted: false,
      notificationsGranted: false,
      bluetoothGranted: false,
    );
  }

  @override
  Future<void> openProtectionSettings() async {}

  @override
  Stream<ProtectionPlatformEvent> watchPlatformEvents() =>
      const Stream<ProtectionPlatformEvent>.empty();
}
