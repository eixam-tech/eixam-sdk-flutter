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
      platformBackgroundCapabilityReady:
          platformBackgroundCapabilityReady ??
              this.platformBackgroundCapabilityReady,
      backendReachable: backendReachable ?? this.backendReachable,
      realtimeReady: realtimeReady ?? this.realtimeReady,
      storeAndForwardEnabled:
          storeAndForwardEnabled ?? this.storeAndForwardEnabled,
      pendingSosCount: pendingSosCount ?? this.pendingSosCount,
      pendingTelemetryCount:
          pendingTelemetryCount ?? this.pendingTelemetryCount,
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
  });

  final DateTime? lastWakeAt;
  final String? lastWakeReason;
  final DateTime? lastDevicePacketAt;
  final DateTime? lastBackendSyncAt;
  final String? lastFailureReason;
  final int pendingSosCount;
  final int pendingTelemetryCount;

  ProtectionDiagnostics copyWith({
    Object? lastWakeAt = _unset,
    Object? lastWakeReason = _unset,
    Object? lastDevicePacketAt = _unset,
    Object? lastBackendSyncAt = _unset,
    Object? lastFailureReason = _unset,
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
