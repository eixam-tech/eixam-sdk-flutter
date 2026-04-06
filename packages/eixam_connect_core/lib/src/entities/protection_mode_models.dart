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
    this.pendingNativeSosCreateCount = 0,
    this.pendingNativeSosCancelCount = 0,
    this.platformRuntimeConfigured = false,
    this.foregroundServiceRunning = false,
    this.protectionRuntimeActive = false,
    this.platform = ProtectionPlatform.unknown,
    this.bleOwner = ProtectionBleOwner.flutter,
    this.backgroundCapabilityState = ProtectionCapabilityState.unknown,
    this.restorationConfigured = false,
    this.serviceBleConnected = false,
    this.serviceBleReady = false,
    this.lastPlatformEvent,
    this.lastPlatformEventAt,
    this.lastRestorationEvent,
    this.lastRestorationEventAt,
    this.lastBleServiceEvent,
    this.lastBleServiceEventAt,
    this.reconnectAttemptCount = 0,
    this.lastReconnectAttemptAt,
    this.lastNativeBackendHandoffResult,
    this.lastNativeBackendHandoffError,
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
  final int pendingNativeSosCreateCount;
  final int pendingNativeSosCancelCount;
  final bool platformRuntimeConfigured;
  final bool foregroundServiceRunning;
  final bool protectionRuntimeActive;
  final ProtectionPlatform platform;
  final ProtectionBleOwner bleOwner;
  final ProtectionCapabilityState backgroundCapabilityState;
  final bool restorationConfigured;
  final bool serviceBleConnected;
  final bool serviceBleReady;
  final String? lastPlatformEvent;
  final DateTime? lastPlatformEventAt;
  final String? lastRestorationEvent;
  final DateTime? lastRestorationEventAt;
  final String? lastBleServiceEvent;
  final DateTime? lastBleServiceEventAt;
  final int reconnectAttemptCount;
  final DateTime? lastReconnectAttemptAt;
  final String? lastNativeBackendHandoffResult;
  final String? lastNativeBackendHandoffError;
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
    int? pendingNativeSosCreateCount,
    int? pendingNativeSosCancelCount,
    bool? platformRuntimeConfigured,
    bool? foregroundServiceRunning,
    bool? protectionRuntimeActive,
    ProtectionPlatform? platform,
    ProtectionBleOwner? bleOwner,
    ProtectionCapabilityState? backgroundCapabilityState,
    bool? restorationConfigured,
    bool? serviceBleConnected,
    bool? serviceBleReady,
    Object? lastPlatformEvent = _unset,
    Object? lastPlatformEventAt = _unset,
    Object? lastRestorationEvent = _unset,
    Object? lastRestorationEventAt = _unset,
    Object? lastBleServiceEvent = _unset,
    Object? lastBleServiceEventAt = _unset,
    int? reconnectAttemptCount,
    Object? lastReconnectAttemptAt = _unset,
    Object? lastNativeBackendHandoffResult = _unset,
    Object? lastNativeBackendHandoffError = _unset,
    Object? activeDeviceId = _unset,
    Object? degradationReason = _unset,
    Object? expectedBleServiceUuid = _unset,
    List<String>? expectedBleCharacteristicUuids,
    Object? discoveredBleServicesSummary = _unset,
    Object? readinessFailureReason = _unset,
    Object? nativeBackendBaseUrl = _unset,
    bool? nativeBackendConfigValid,
    Object? nativeBackendConfigIssue = _unset,
    bool? debugLocalhostBackendAllowed,
    bool? debugCleartextBackendAllowed,
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
      pendingNativeSosCreateCount:
          pendingNativeSosCreateCount ?? this.pendingNativeSosCreateCount,
      pendingNativeSosCancelCount:
          pendingNativeSosCancelCount ?? this.pendingNativeSosCancelCount,
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
      restorationConfigured:
          restorationConfigured ?? this.restorationConfigured,
      serviceBleConnected: serviceBleConnected ?? this.serviceBleConnected,
      serviceBleReady: serviceBleReady ?? this.serviceBleReady,
      lastPlatformEvent: identical(lastPlatformEvent, _unset)
          ? this.lastPlatformEvent
          : lastPlatformEvent as String?,
      lastPlatformEventAt: identical(lastPlatformEventAt, _unset)
          ? this.lastPlatformEventAt
          : lastPlatformEventAt as DateTime?,
      lastRestorationEvent: identical(lastRestorationEvent, _unset)
          ? this.lastRestorationEvent
          : lastRestorationEvent as String?,
      lastRestorationEventAt: identical(lastRestorationEventAt, _unset)
          ? this.lastRestorationEventAt
          : lastRestorationEventAt as DateTime?,
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
      lastNativeBackendHandoffResult:
          identical(lastNativeBackendHandoffResult, _unset)
              ? this.lastNativeBackendHandoffResult
              : lastNativeBackendHandoffResult as String?,
      lastNativeBackendHandoffError:
          identical(lastNativeBackendHandoffError, _unset)
              ? this.lastNativeBackendHandoffError
              : lastNativeBackendHandoffError as String?,
      activeDeviceId: identical(activeDeviceId, _unset)
          ? this.activeDeviceId
          : activeDeviceId as String?,
      degradationReason: identical(degradationReason, _unset)
          ? this.degradationReason
          : degradationReason as String?,
      expectedBleServiceUuid: identical(expectedBleServiceUuid, _unset)
          ? this.expectedBleServiceUuid
          : expectedBleServiceUuid as String?,
      expectedBleCharacteristicUuids:
          expectedBleCharacteristicUuids ?? this.expectedBleCharacteristicUuids,
      discoveredBleServicesSummary:
          identical(discoveredBleServicesSummary, _unset)
              ? this.discoveredBleServicesSummary
              : discoveredBleServicesSummary as String?,
      readinessFailureReason: identical(readinessFailureReason, _unset)
          ? this.readinessFailureReason
          : readinessFailureReason as String?,
      nativeBackendBaseUrl: identical(nativeBackendBaseUrl, _unset)
          ? this.nativeBackendBaseUrl
          : nativeBackendBaseUrl as String?,
      nativeBackendConfigValid:
          nativeBackendConfigValid ?? this.nativeBackendConfigValid,
      nativeBackendConfigIssue: identical(nativeBackendConfigIssue, _unset)
          ? this.nativeBackendConfigIssue
          : nativeBackendConfigIssue as String?,
      debugLocalhostBackendAllowed: debugLocalhostBackendAllowed ??
          this.debugLocalhostBackendAllowed,
      debugCleartextBackendAllowed: debugCleartextBackendAllowed ??
          this.debugCleartextBackendAllowed,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  static const Object _unset = Object();
}

class ProtectionDiagnostics {
  const ProtectionDiagnostics({
    required this.pendingSosCount,
    required this.pendingTelemetryCount,
    this.pendingNativeSosCreateCount = 0,
    this.pendingNativeSosCancelCount = 0,
    this.lastWakeAt,
    this.lastWakeReason,
    this.lastDevicePacketAt,
    this.lastBackendSyncAt,
    this.lastFailureReason,
    this.lastPlatformEvent,
    this.lastPlatformEventAt,
    this.lastRestorationEvent,
    this.lastRestorationEventAt,
    this.lastBleServiceEvent,
    this.lastBleServiceEventAt,
    this.reconnectAttemptCount = 0,
    this.lastReconnectAttemptAt,
    this.lastNativeBackendHandoffResult,
    this.lastNativeBackendHandoffError,
    this.expectedBleServiceUuid,
    this.expectedBleCharacteristicUuids = const <String>[],
    this.discoveredBleServicesSummary,
    this.readinessFailureReason,
    this.nativeBackendBaseUrl,
    this.nativeBackendConfigValid = true,
    this.nativeBackendConfigIssue,
    this.debugLocalhostBackendAllowed = false,
    this.debugCleartextBackendAllowed = false,
  });

  final DateTime? lastWakeAt;
  final String? lastWakeReason;
  final DateTime? lastDevicePacketAt;
  final DateTime? lastBackendSyncAt;
  final String? lastFailureReason;
  final String? lastPlatformEvent;
  final DateTime? lastPlatformEventAt;
  final String? lastRestorationEvent;
  final DateTime? lastRestorationEventAt;
  final String? lastBleServiceEvent;
  final DateTime? lastBleServiceEventAt;
  final int reconnectAttemptCount;
  final DateTime? lastReconnectAttemptAt;
  final int pendingSosCount;
  final int pendingTelemetryCount;
  final int pendingNativeSosCreateCount;
  final int pendingNativeSosCancelCount;
  final String? lastNativeBackendHandoffResult;
  final String? lastNativeBackendHandoffError;
  final String? expectedBleServiceUuid;
  final List<String> expectedBleCharacteristicUuids;
  final String? discoveredBleServicesSummary;
  final String? readinessFailureReason;
  final String? nativeBackendBaseUrl;
  final bool nativeBackendConfigValid;
  final String? nativeBackendConfigIssue;
  final bool debugLocalhostBackendAllowed;
  final bool debugCleartextBackendAllowed;

  ProtectionDiagnostics copyWith({
    Object? lastWakeAt = _unset,
    Object? lastWakeReason = _unset,
    Object? lastDevicePacketAt = _unset,
    Object? lastBackendSyncAt = _unset,
    Object? lastFailureReason = _unset,
    Object? lastPlatformEvent = _unset,
    Object? lastPlatformEventAt = _unset,
    Object? lastRestorationEvent = _unset,
    Object? lastRestorationEventAt = _unset,
    Object? lastBleServiceEvent = _unset,
    Object? lastBleServiceEventAt = _unset,
    int? reconnectAttemptCount,
    Object? lastReconnectAttemptAt = _unset,
    int? pendingSosCount,
    int? pendingTelemetryCount,
    int? pendingNativeSosCreateCount,
    int? pendingNativeSosCancelCount,
    Object? lastNativeBackendHandoffResult = _unset,
    Object? lastNativeBackendHandoffError = _unset,
    Object? expectedBleServiceUuid = _unset,
    List<String>? expectedBleCharacteristicUuids,
    Object? discoveredBleServicesSummary = _unset,
    Object? readinessFailureReason = _unset,
    Object? nativeBackendBaseUrl = _unset,
    bool? nativeBackendConfigValid,
    Object? nativeBackendConfigIssue = _unset,
    bool? debugLocalhostBackendAllowed,
    bool? debugCleartextBackendAllowed,
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
      lastRestorationEvent: identical(lastRestorationEvent, _unset)
          ? this.lastRestorationEvent
          : lastRestorationEvent as String?,
      lastRestorationEventAt: identical(lastRestorationEventAt, _unset)
          ? this.lastRestorationEventAt
          : lastRestorationEventAt as DateTime?,
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
      pendingNativeSosCreateCount:
          pendingNativeSosCreateCount ?? this.pendingNativeSosCreateCount,
      pendingNativeSosCancelCount:
          pendingNativeSosCancelCount ?? this.pendingNativeSosCancelCount,
      lastNativeBackendHandoffResult:
          identical(lastNativeBackendHandoffResult, _unset)
              ? this.lastNativeBackendHandoffResult
              : lastNativeBackendHandoffResult as String?,
      lastNativeBackendHandoffError:
          identical(lastNativeBackendHandoffError, _unset)
              ? this.lastNativeBackendHandoffError
              : lastNativeBackendHandoffError as String?,
      expectedBleServiceUuid: identical(expectedBleServiceUuid, _unset)
          ? this.expectedBleServiceUuid
          : expectedBleServiceUuid as String?,
      expectedBleCharacteristicUuids:
          expectedBleCharacteristicUuids ?? this.expectedBleCharacteristicUuids,
      discoveredBleServicesSummary:
          identical(discoveredBleServicesSummary, _unset)
              ? this.discoveredBleServicesSummary
              : discoveredBleServicesSummary as String?,
      readinessFailureReason: identical(readinessFailureReason, _unset)
          ? this.readinessFailureReason
          : readinessFailureReason as String?,
      nativeBackendBaseUrl: identical(nativeBackendBaseUrl, _unset)
          ? this.nativeBackendBaseUrl
          : nativeBackendBaseUrl as String?,
      nativeBackendConfigValid:
          nativeBackendConfigValid ?? this.nativeBackendConfigValid,
      nativeBackendConfigIssue: identical(nativeBackendConfigIssue, _unset)
          ? this.nativeBackendConfigIssue
          : nativeBackendConfigIssue as String?,
      debugLocalhostBackendAllowed: debugLocalhostBackendAllowed ??
          this.debugLocalhostBackendAllowed,
      debugCleartextBackendAllowed: debugCleartextBackendAllowed ??
          this.debugCleartextBackendAllowed,
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
