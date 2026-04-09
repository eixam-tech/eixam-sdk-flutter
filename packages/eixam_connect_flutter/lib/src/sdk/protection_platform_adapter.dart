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
  packetReceived,
  sosEventReceived,
  runtimeError,
  restorationDetected,
  restorationRehydrated,
  nativeBackendSyncQueued,
  nativeBackendSyncSucceeded,
  nativeBackendSyncFailed,
  bluetoothTurnedOff,
  bluetoothTurnedOn,
}

class ProtectionPlatformStartRequest {
  const ProtectionPlatformStartRequest({
    required this.modeOptions,
    this.activeDeviceId,
    this.backendHardwareId,
    this.apiBaseUrl,
    this.sessionReady = false,
    this.enableStoreAndForward = true,
  });

  final ProtectionModeOptions modeOptions;
  final String? activeDeviceId;
  final String? backendHardwareId;
  final String? apiBaseUrl;
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
    this.restorationConfigured = false,
    this.bleOwner = ProtectionBleOwner.flutter,
    this.serviceBleConnected = false,
    this.serviceBleReady = false,
    this.pendingSosCount = 0,
    this.pendingTelemetryCount = 0,
    this.pendingNativeSosCreateCount = 0,
    this.pendingNativeSosCancelCount = 0,
    this.lastRestorationEvent,
    this.lastRestorationEventAt,
    this.lastBleServiceEvent,
    this.lastBleServiceEventAt,
    this.reconnectAttemptCount = 0,
    this.lastReconnectAttemptAt,
    this.lastNativeBackendHandoffResult,
    this.lastNativeBackendHandoffError,
    this.protectedDeviceId,
    this.activeDeviceId,
    this.degradationReason,
    this.expectedBleServiceUuid,
    this.expectedBleCharacteristicUuids = const <String>[],
    this.discoveredBleServicesSummary,
    this.readinessFailureReason,
    this.nativeBackendBaseUrl,
    this.nativeBackendConfigValid = true,
    this.nativeBackendConfigIssue,
    this.debugLocalhostBackendAllowed = false,
    this.debugCleartextBackendAllowed = false,
    this.lastCommandRoute,
    this.lastCommandResult,
    this.lastCommandError,
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
  final bool restorationConfigured;
  final ProtectionBleOwner bleOwner;
  final bool serviceBleConnected;
  final bool serviceBleReady;
  final int pendingSosCount;
  final int pendingTelemetryCount;
  final int pendingNativeSosCreateCount;
  final int pendingNativeSosCancelCount;
  final String? lastRestorationEvent;
  final DateTime? lastRestorationEventAt;
  final String? lastBleServiceEvent;
  final DateTime? lastBleServiceEventAt;
  final int reconnectAttemptCount;
  final DateTime? lastReconnectAttemptAt;
  final String? lastNativeBackendHandoffResult;
  final String? lastNativeBackendHandoffError;
  final String? protectedDeviceId;
  final String? activeDeviceId;
  final String? degradationReason;
  final String? expectedBleServiceUuid;
  final List<String> expectedBleCharacteristicUuids;
  final String? discoveredBleServicesSummary;
  final String? readinessFailureReason;
  final String? nativeBackendBaseUrl;
  final bool nativeBackendConfigValid;
  final String? nativeBackendConfigIssue;
  final bool debugLocalhostBackendAllowed;
  final bool debugCleartextBackendAllowed;
  final String? lastCommandRoute;
  final String? lastCommandResult;
  final String? lastCommandError;
}

class ProtectionPlatformCommandRequest {
  const ProtectionPlatformCommandRequest({
    required this.label,
    required this.bytes,
    this.forceCmdCharacteristic = false,
  });

  final String label;
  final List<int> bytes;
  final bool forceCmdCharacteristic;
}

class ProtectionPlatformCommandResult {
  const ProtectionPlatformCommandResult({
    required this.success,
    this.route,
    this.result,
    this.error,
  });

  final bool success;
  final String? route;
  final String? result;
  final String? error;
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
  ProtectionPlatform get platform;
  Future<ProtectionPlatformSnapshot> getPlatformSnapshot();
  Future<ProtectionPlatformStartResult> startProtectionRuntime({
    required ProtectionPlatformStartRequest request,
  });
  Future<void> stopProtectionRuntime();
  Future<void> ensureProtectionRuntimeActive({
    String reason = 'app_foreground_resume',
  });
  Future<ProtectionPlatformFlushResult> flushProtectionQueues();
  Future<ProtectionPlatformCommandResult> sendProtectionCommand({
    required ProtectionPlatformCommandRequest request,
  });
  Future<ProtectionPermissionResult> requestProtectionPermissions();
  Future<void> openProtectionSettings();
  Stream<ProtectionPlatformEvent> watchPlatformEvents();
}

class NoopProtectionPlatformAdapter implements ProtectionPlatformAdapter {
  const NoopProtectionPlatformAdapter();

  @override
  ProtectionPlatform get platform => ProtectionPlatform.unknown;

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
  Future<void> ensureProtectionRuntimeActive({
    String reason = 'app_foreground_resume',
  }) async {}

  @override
  Future<ProtectionPlatformFlushResult> flushProtectionQueues() async {
    return const ProtectionPlatformFlushResult();
  }

  @override
  Future<ProtectionPlatformCommandResult> sendProtectionCommand({
    required ProtectionPlatformCommandRequest request,
  }) async {
    return const ProtectionPlatformCommandResult(
      success: false,
      route: 'flutter',
      error: 'Protection platform runtime is not configured.',
    );
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
