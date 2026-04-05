enum ProtectionModeState {
  off,
  arming,
  armed,
  degraded,
  stopping,
  error,
}

enum ProtectionCoverageLevel {
  none,
  partial,
  full,
}

enum ProtectionBleOwner {
  flutter,
  androidService,
}

enum ProtectionPlatform {
  unknown,
  android,
  ios,
}

enum ProtectionCapabilityState {
  unknown,
  unavailable,
  configured,
}

enum ProtectionRuntimeState {
  inactive,
  starting,
  active,
  recovering,
  failed,
}

enum ProtectionBlockingIssueType {
  noSession,
  noPairedDevice,
  bluetoothDisabled,
  locationPermissionMissing,
  notificationsPermissionMissing,
  platformBackgroundCapabilityMissing,
  hostRuntimeStartFailed,
}

class ProtectionStatus {
  const ProtectionStatus({
    required this.modeState,
    required this.coverageLevel,
    required this.runtimeState,
    required this.sessionReady,
    required this.devicePaired,
    required this.deviceConnected,
    required this.bluetoothEnabled,
    required this.locationPermissionGranted,
    required this.notificationsPermissionGranted,
    required this.platformBackgroundCapabilityReady,
    required this.backendReachable,
    required this.realtimeReady,
    required this.storeAndForwardEnabled,
    required this.pendingSosCount,
    required this.pendingTelemetryCount,
    required this.updatedAt,
    this.platformRuntimeConfigured = false,
    this.foregroundServiceRunning = false,
    this.protectionRuntimeActive = false,
    this.platform = ProtectionPlatform.unknown,
    this.bleOwner = ProtectionBleOwner.flutter,
    this.backgroundCapabilityState = ProtectionCapabilityState.unknown,
    this.serviceBleConnected = false,
    this.serviceBleReady = false,
    this.lastPlatformEvent,
    this.lastPlatformEventAt,
    this.lastBleServiceEvent,
    this.lastBleServiceEventAt,
    this.reconnectAttemptCount = 0,
    this.lastReconnectAttemptAt,
    this.activeDeviceId,
    this.degradationReason,
  });

  final ProtectionModeState modeState;
  final ProtectionCoverageLevel coverageLevel;
  final ProtectionRuntimeState runtimeState;
  final bool sessionReady;
  final bool devicePaired;
  final bool deviceConnected;
  final bool bluetoothEnabled;
  final bool locationPermissionGranted;
  final bool notificationsPermissionGranted;
  final bool platformBackgroundCapabilityReady;
  final bool backendReachable;
  final bool realtimeReady;
  final bool storeAndForwardEnabled;
  final int pendingSosCount;
  final int pendingTelemetryCount;
  final bool platformRuntimeConfigured;
  final bool foregroundServiceRunning;
  final bool protectionRuntimeActive;
  final ProtectionPlatform platform;
  final ProtectionBleOwner bleOwner;
  final ProtectionCapabilityState backgroundCapabilityState;
  final bool serviceBleConnected;
  final bool serviceBleReady;
  final String? lastPlatformEvent;
  final DateTime? lastPlatformEventAt;
  final String? lastBleServiceEvent;
  final DateTime? lastBleServiceEventAt;
  final int reconnectAttemptCount;
  final DateTime? lastReconnectAttemptAt;
  final String? activeDeviceId;
  final String? degradationReason;
  final DateTime updatedAt;

  ProtectionStatus copyWith({
    ProtectionModeState? modeState,
    ProtectionCoverageLevel? coverageLevel,
    ProtectionRuntimeState? runtimeState,
    bool? sessionReady,
    bool? devicePaired,
    bool? deviceConnected,
    bool? bluetoothEnabled,
    bool? locationPermissionGranted,
    bool? notificationsPermissionGranted,
    bool? platformBackgroundCapabilityReady,
    bool? backendReachable,
    bool? realtimeReady,
    bool? storeAndForwardEnabled,
    int? pendingSosCount,
    int? pendingTelemetryCount,
    bool? platformRuntimeConfigured,
    bool? foregroundServiceRunning,
    bool? protectionRuntimeActive,
    ProtectionPlatform? platform,
    ProtectionBleOwner? bleOwner,
    ProtectionCapabilityState? backgroundCapabilityState,
    bool? serviceBleConnected,
    bool? serviceBleReady,
    Object? lastPlatformEvent = _unset,
    Object? lastPlatformEventAt = _unset,
    Object? lastBleServiceEvent = _unset,
    Object? lastBleServiceEventAt = _unset,
    int? reconnectAttemptCount,
    Object? lastReconnectAttemptAt = _unset,
    Object? activeDeviceId = _unset,
    Object? degradationReason = _unset,
    DateTime? updatedAt,
  }) {
    return ProtectionStatus(
      modeState: modeState ?? this.modeState,
      coverageLevel: coverageLevel ?? this.coverageLevel,
      runtimeState: runtimeState ?? this.runtimeState,
      sessionReady: sessionReady ?? this.sessionReady,
      devicePaired: devicePaired ?? this.devicePaired,
      deviceConnected: deviceConnected ?? this.deviceConnected,
      bluetoothEnabled: bluetoothEnabled ?? this.bluetoothEnabled,
      locationPermissionGranted:
          locationPermissionGranted ?? this.locationPermissionGranted,
      notificationsPermissionGranted:
          notificationsPermissionGranted ?? this.notificationsPermissionGranted,
      platformBackgroundCapabilityReady: platformBackgroundCapabilityReady ??
          this.platformBackgroundCapabilityReady,
      backendReachable: backendReachable ?? this.backendReachable,
      realtimeReady: realtimeReady ?? this.realtimeReady,
      storeAndForwardEnabled:
          storeAndForwardEnabled ?? this.storeAndForwardEnabled,
      pendingSosCount: pendingSosCount ?? this.pendingSosCount,
      pendingTelemetryCount:
          pendingTelemetryCount ?? this.pendingTelemetryCount,
      platformRuntimeConfigured:
          platformRuntimeConfigured ?? this.platformRuntimeConfigured,
      foregroundServiceRunning:
          foregroundServiceRunning ?? this.foregroundServiceRunning,
      protectionRuntimeActive:
          protectionRuntimeActive ?? this.protectionRuntimeActive,
      platform: platform ?? this.platform,
      bleOwner: bleOwner ?? this.bleOwner,
      backgroundCapabilityState:
          backgroundCapabilityState ?? this.backgroundCapabilityState,
      serviceBleConnected: serviceBleConnected ?? this.serviceBleConnected,
      serviceBleReady: serviceBleReady ?? this.serviceBleReady,
      lastPlatformEvent: identical(lastPlatformEvent, _unset)
          ? this.lastPlatformEvent
          : lastPlatformEvent as String?,
      lastPlatformEventAt: identical(lastPlatformEventAt, _unset)
          ? this.lastPlatformEventAt
          : lastPlatformEventAt as DateTime?,
      lastBleServiceEvent: identical(lastBleServiceEvent, _unset)
          ? this.lastBleServiceEvent
          : lastBleServiceEvent as String?,
      lastBleServiceEventAt: identical(lastBleServiceEventAt, _unset)
          ? this.lastBleServiceEventAt
          : lastBleServiceEventAt as DateTime?,
      reconnectAttemptCount:
          reconnectAttemptCount ?? this.reconnectAttemptCount,
      lastReconnectAttemptAt: identical(lastReconnectAttemptAt, _unset)
          ? this.lastReconnectAttemptAt
          : lastReconnectAttemptAt as DateTime?,
      activeDeviceId: identical(activeDeviceId, _unset)
          ? this.activeDeviceId
          : activeDeviceId as String?,
      degradationReason: identical(degradationReason, _unset)
          ? this.degradationReason
          : degradationReason as String?,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  static const Object _unset = Object();
}

class ProtectionDiagnostics {
  const ProtectionDiagnostics({
    required this.pendingSosCount,
    required this.pendingTelemetryCount,
    this.lastWakeAt,
    this.lastWakeReason,
    this.lastDevicePacketAt,
    this.lastBackendSyncAt,
    this.lastFailureReason,
    this.lastPlatformEvent,
    this.lastPlatformEventAt,
    this.lastBleServiceEvent,
    this.lastBleServiceEventAt,
    this.reconnectAttemptCount = 0,
    this.lastReconnectAttemptAt,
  });

  final DateTime? lastWakeAt;
  final String? lastWakeReason;
  final DateTime? lastDevicePacketAt;
  final DateTime? lastBackendSyncAt;
  final String? lastFailureReason;
  final String? lastPlatformEvent;
  final DateTime? lastPlatformEventAt;
  final String? lastBleServiceEvent;
  final DateTime? lastBleServiceEventAt;
  final int reconnectAttemptCount;
  final DateTime? lastReconnectAttemptAt;
  final int pendingSosCount;
  final int pendingTelemetryCount;

  ProtectionDiagnostics copyWith({
    Object? lastWakeAt = _unset,
    Object? lastWakeReason = _unset,
    Object? lastDevicePacketAt = _unset,
    Object? lastBackendSyncAt = _unset,
    Object? lastFailureReason = _unset,
    Object? lastPlatformEvent = _unset,
    Object? lastPlatformEventAt = _unset,
    Object? lastBleServiceEvent = _unset,
    Object? lastBleServiceEventAt = _unset,
    int? reconnectAttemptCount,
    Object? lastReconnectAttemptAt = _unset,
    int? pendingSosCount,
    int? pendingTelemetryCount,
  }) {
    return ProtectionDiagnostics(
      lastWakeAt: identical(lastWakeAt, _unset)
          ? this.lastWakeAt
          : lastWakeAt as DateTime?,
      lastWakeReason: identical(lastWakeReason, _unset)
          ? this.lastWakeReason
          : lastWakeReason as String?,
      lastDevicePacketAt: identical(lastDevicePacketAt, _unset)
          ? this.lastDevicePacketAt
          : lastDevicePacketAt as DateTime?,
      lastBackendSyncAt: identical(lastBackendSyncAt, _unset)
          ? this.lastBackendSyncAt
          : lastBackendSyncAt as DateTime?,
      lastFailureReason: identical(lastFailureReason, _unset)
          ? this.lastFailureReason
          : lastFailureReason as String?,
      lastPlatformEvent: identical(lastPlatformEvent, _unset)
          ? this.lastPlatformEvent
          : lastPlatformEvent as String?,
      lastPlatformEventAt: identical(lastPlatformEventAt, _unset)
          ? this.lastPlatformEventAt
          : lastPlatformEventAt as DateTime?,
      lastBleServiceEvent: identical(lastBleServiceEvent, _unset)
          ? this.lastBleServiceEvent
          : lastBleServiceEvent as String?,
      lastBleServiceEventAt: identical(lastBleServiceEventAt, _unset)
          ? this.lastBleServiceEventAt
          : lastBleServiceEventAt as DateTime?,
      reconnectAttemptCount:
          reconnectAttemptCount ?? this.reconnectAttemptCount,
      lastReconnectAttemptAt: identical(lastReconnectAttemptAt, _unset)
          ? this.lastReconnectAttemptAt
          : lastReconnectAttemptAt as DateTime?,
      pendingSosCount: pendingSosCount ?? this.pendingSosCount,
      pendingTelemetryCount:
          pendingTelemetryCount ?? this.pendingTelemetryCount,
    );
  }

  static const Object _unset = Object();
}

class ProtectionBlockingIssue {
  const ProtectionBlockingIssue({
    required this.type,
    required this.message,
    required this.canBeResolvedInline,
  });

  final ProtectionBlockingIssueType type;
  final String message;
  final bool canBeResolvedInline;
}

class ProtectionReadinessReport {
  const ProtectionReadinessReport({
    required this.canArm,
    this.blockingIssues = const <ProtectionBlockingIssue>[],
    this.warnings = const <String>[],
  });

  final bool canArm;
  final List<ProtectionBlockingIssue> blockingIssues;
  final List<String> warnings;
}

class ProtectionModeOptions {
  final bool enableStoreAndForward;
  final bool autoReconnectBle;
  final bool autoFlushOnReconnect;
  final bool allowDegradedMode;
  final Duration reconnectBackoff;
  final Duration healthCheckInterval;

  const ProtectionModeOptions({
    this.enableStoreAndForward = true,
    this.autoReconnectBle = true,
    this.autoFlushOnReconnect = true,
    this.allowDegradedMode = true,
    this.reconnectBackoff = const Duration(seconds: 10),
    this.healthCheckInterval = const Duration(seconds: 30),
  });
}

class EnterProtectionModeResult {
  const EnterProtectionModeResult({
    required this.success,
    required this.status,
    this.blockingIssues = const <ProtectionBlockingIssue>[],
  });

  final bool success;
  final ProtectionStatus status;
  final List<ProtectionBlockingIssue> blockingIssues;
}

class FlushProtectionQueuesResult {
  const FlushProtectionQueuesResult({
    required this.flushedSosCount,
    required this.flushedTelemetryCount,
    required this.success,
  });

  final int flushedSosCount;
  final int flushedTelemetryCount;
  final bool success;
}
