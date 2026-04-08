import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'protection_platform_adapter.dart';

ProtectionPlatformSnapshot mapIosProtectionPlatformSnapshot(
  Map<String, dynamic> snapshot,
) {
  return ProtectionPlatformSnapshot(
    backgroundCapabilityReady:
        snapshot['backgroundCapabilityReady'] as bool? ?? false,
    platformRuntimeConfigured:
        snapshot['platformRuntimeConfigured'] as bool? ?? false,
    serviceRunning: false,
    runtimeActive: snapshot['runtimeActive'] as bool? ?? false,
    bluetoothEnabled: snapshot['bluetoothEnabled'] as bool?,
    notificationsGranted: snapshot['notificationsGranted'] as bool?,
    lastFailureReason: snapshot['lastFailureReason'] as String?,
    lastPlatformEvent: snapshot['lastPlatformEvent'] as String?,
    lastPlatformEventAt: readProtectionPlatformDateTime(
      snapshot['lastPlatformEventAt'],
    ),
    runtimeState: parseProtectionRuntimeState(
      snapshot['runtimeState'] as String?,
    ),
    coverageLevel: parseProtectionCoverageLevel(
      snapshot['coverageLevel'] as String?,
    ),
    lastWakeAt: readProtectionPlatformDateTime(snapshot['lastWakeAt']),
    lastWakeReason: snapshot['lastWakeReason'] as String?,
    platform: ProtectionPlatform.ios,
    backgroundCapabilityState: parseProtectionCapabilityState(
      snapshot['backgroundCapabilityState'] as String?,
    ),
    restorationConfigured: snapshot['restorationConfigured'] as bool? ?? false,
    bleOwner: parseProtectionBleOwner(snapshot['bleOwner'] as String?),
    serviceBleConnected: snapshot['serviceBleConnected'] as bool? ?? false,
    serviceBleReady: snapshot['serviceBleReady'] as bool? ?? false,
    pendingSosCount: snapshot['pendingSosCount'] as int? ?? 0,
    pendingTelemetryCount: snapshot['pendingTelemetryCount'] as int? ?? 0,
    lastRestorationEvent: snapshot['lastRestorationEvent'] as String?,
    lastRestorationEventAt: readProtectionPlatformDateTime(
      snapshot['lastRestorationEventAt'],
    ),
    lastBleServiceEvent: snapshot['lastBleServiceEvent'] as String?,
    lastBleServiceEventAt: readProtectionPlatformDateTime(
      snapshot['lastBleServiceEventAt'],
    ),
    reconnectAttemptCount: snapshot['reconnectAttemptCount'] as int? ?? 0,
    lastReconnectAttemptAt: readProtectionPlatformDateTime(
      snapshot['lastReconnectAttemptAt'],
    ),
    protectedDeviceId: snapshot['protectedDeviceId'] as String? ??
        snapshot['activeDeviceId'] as String?,
    activeDeviceId: snapshot['activeDeviceId'] as String?,
    degradationReason: snapshot['degradationReason'] as String?,
    expectedBleServiceUuid: snapshot['expectedBleServiceUuid'] as String?,
    expectedBleCharacteristicUuids:
        (snapshot['expectedBleCharacteristicUuids'] as List<dynamic>? ??
                const <dynamic>[])
            .whereType<String>()
            .toList(growable: false),
    discoveredBleServicesSummary:
        snapshot['discoveredBleServicesSummary'] as String?,
    readinessFailureReason: snapshot['readinessFailureReason'] as String?,
    nativeBackendConfigValid:
        snapshot['nativeBackendConfigValid'] as bool? ?? true,
    nativeBackendConfigIssue: snapshot['nativeBackendConfigIssue'] as String?,
    lastCommandRoute: snapshot['lastCommandRoute'] as String?,
    lastCommandResult: snapshot['lastCommandResult'] as String?,
    lastCommandError: snapshot['lastCommandError'] as String?,
  );
}

ProtectionPlatformSnapshot mapAndroidProtectionPlatformSnapshot(
  Map<String, dynamic> snapshot,
) {
  return ProtectionPlatformSnapshot(
    backgroundCapabilityReady:
        snapshot['backgroundCapabilityReady'] as bool? ?? false,
    platformRuntimeConfigured:
        snapshot['platformRuntimeConfigured'] as bool? ?? false,
    foregroundServiceConfigured:
        snapshot['foregroundServiceConfigured'] as bool? ?? false,
    serviceRunning: snapshot['serviceRunning'] as bool? ?? false,
    runtimeActive: snapshot['runtimeActive'] as bool? ?? false,
    bluetoothEnabled: snapshot['bluetoothEnabled'] as bool?,
    notificationsGranted: snapshot['notificationsGranted'] as bool?,
    lastFailureReason: snapshot['lastFailureReason'] as String?,
    lastPlatformEvent: snapshot['lastPlatformEvent'] as String?,
    lastPlatformEventAt: readProtectionPlatformDateTime(
      snapshot['lastPlatformEventAt'],
    ),
    runtimeState: parseProtectionRuntimeState(
      snapshot['runtimeState'] as String?,
    ),
    coverageLevel: parseProtectionCoverageLevel(
      snapshot['coverageLevel'] as String?,
    ),
    lastWakeAt: readProtectionPlatformDateTime(snapshot['lastWakeAt']),
    lastWakeReason: snapshot['lastWakeReason'] as String?,
    platform: ProtectionPlatform.android,
    backgroundCapabilityState: parseProtectionCapabilityState(
      snapshot['backgroundCapabilityState'] as String?,
    ),
    restorationConfigured: snapshot['restorationConfigured'] as bool? ?? false,
    bleOwner: parseProtectionBleOwner(snapshot['bleOwner'] as String?),
    serviceBleConnected: snapshot['serviceBleConnected'] as bool? ?? false,
    serviceBleReady: snapshot['serviceBleReady'] as bool? ?? false,
    pendingSosCount: snapshot['pendingSosCount'] as int? ?? 0,
    pendingTelemetryCount: snapshot['pendingTelemetryCount'] as int? ?? 0,
    pendingNativeSosCreateCount:
        snapshot['pendingNativeSosCreateCount'] as int? ?? 0,
    pendingNativeSosCancelCount:
        snapshot['pendingNativeSosCancelCount'] as int? ?? 0,
    lastRestorationEvent: snapshot['lastRestorationEvent'] as String?,
    lastRestorationEventAt: readProtectionPlatformDateTime(
      snapshot['lastRestorationEventAt'],
    ),
    lastBleServiceEvent: snapshot['lastBleServiceEvent'] as String?,
    lastBleServiceEventAt: readProtectionPlatformDateTime(
      snapshot['lastBleServiceEventAt'],
    ),
    reconnectAttemptCount: snapshot['reconnectAttemptCount'] as int? ?? 0,
    lastReconnectAttemptAt: readProtectionPlatformDateTime(
      snapshot['lastReconnectAttemptAt'],
    ),
    lastNativeBackendHandoffResult:
        snapshot['lastNativeBackendHandoffResult'] as String?,
    lastNativeBackendHandoffError:
        snapshot['lastNativeBackendHandoffError'] as String?,
    protectedDeviceId: snapshot['protectedDeviceId'] as String? ??
        snapshot['targetDeviceId'] as String? ??
        snapshot['activeDeviceId'] as String?,
    activeDeviceId: snapshot['activeDeviceId'] as String?,
    degradationReason: snapshot['degradationReason'] as String?,
    expectedBleServiceUuid: snapshot['expectedBleServiceUuid'] as String?,
    expectedBleCharacteristicUuids:
        (snapshot['expectedBleCharacteristicUuids'] as List<dynamic>? ??
                const <dynamic>[])
            .map((value) => value.toString())
            .toList(growable: false),
    discoveredBleServicesSummary:
        snapshot['discoveredBleServicesSummary'] as String?,
    readinessFailureReason: snapshot['readinessFailureReason'] as String?,
    nativeBackendBaseUrl: snapshot['nativeBackendBaseUrl'] as String?,
    nativeBackendConfigValid:
        snapshot['nativeBackendConfigValid'] as bool? ?? true,
    nativeBackendConfigIssue: snapshot['nativeBackendConfigIssue'] as String?,
    debugLocalhostBackendAllowed:
        snapshot['debugLocalhostBackendAllowed'] as bool? ?? false,
    debugCleartextBackendAllowed:
        snapshot['debugCleartextBackendAllowed'] as bool? ?? false,
    lastCommandRoute: snapshot['lastCommandRoute'] as String?,
    lastCommandResult: snapshot['lastCommandResult'] as String?,
    lastCommandError: snapshot['lastCommandError'] as String?,
  );
}

ProtectionPlatformStartResult mapProtectionPlatformStartResult(
  Map<String, dynamic> result,
) {
  return ProtectionPlatformStartResult(
    success: result['success'] as bool? ?? false,
    runtimeState:
        parseProtectionRuntimeState(result['runtimeState'] as String?),
    coverageLevel: parseProtectionCoverageLevel(
      result['coverageLevel'] as String?,
    ),
    failureReason: result['failureReason'] as String?,
    statusMessage: result['statusMessage'] as String?,
  );
}

ProtectionPlatformFlushResult mapProtectionPlatformFlushResult(
  Map<String, dynamic> result,
) {
  return ProtectionPlatformFlushResult(
    flushedSosCount: result['flushedSosCount'] as int? ?? 0,
    flushedTelemetryCount: result['flushedTelemetryCount'] as int? ?? 0,
    success: result['success'] as bool? ?? true,
  );
}

ProtectionPlatformCommandResult mapProtectionPlatformCommandResult(
  Map<String, dynamic> result,
) {
  return ProtectionPlatformCommandResult(
    success: result['success'] as bool? ?? false,
    route: result['route'] as String?,
    result: result['result'] as String?,
    error: result['error'] as String?,
  );
}

ProtectionPlatformEvent mapIosProtectionPlatformEvent(
  Map<Object?, Object?> data,
) {
  return ProtectionPlatformEvent(
    type: parseIosProtectionPlatformEventType(data['type'] as String?),
    timestamp: readProtectionPlatformDateTime(data['timestamp']) ??
        DateTime.now().toUtc(),
    reason: data['reason'] as String?,
  );
}

ProtectionPlatformEvent mapAndroidProtectionPlatformEvent(
  Map<Object?, Object?> data,
) {
  return ProtectionPlatformEvent(
    type: parseAndroidProtectionPlatformEventType(data['type'] as String?),
    timestamp: readProtectionPlatformDateTime(data['timestamp']) ??
        DateTime.now().toUtc(),
    reason: data['reason'] as String?,
  );
}

ProtectionPlatformEventType parseIosProtectionPlatformEventType(String? value) {
  switch (value) {
    case 'runtimeStarting':
      return ProtectionPlatformEventType.runtimeStarting;
    case 'runtimeActive':
      return ProtectionPlatformEventType.runtimeActive;
    case 'runtimeRecovered':
      return ProtectionPlatformEventType.runtimeRecovered;
    case 'runtimeStopped':
      return ProtectionPlatformEventType.runtimeStopped;
    case 'runtimeFailed':
      return ProtectionPlatformEventType.runtimeFailed;
    case 'deviceConnecting':
      return ProtectionPlatformEventType.deviceConnecting;
    case 'deviceConnected':
      return ProtectionPlatformEventType.deviceConnected;
    case 'deviceDisconnected':
      return ProtectionPlatformEventType.deviceDisconnected;
    case 'reconnectScheduled':
      return ProtectionPlatformEventType.reconnectScheduled;
    case 'reconnectFailed':
      return ProtectionPlatformEventType.reconnectFailed;
    case 'servicesDiscovered':
      return ProtectionPlatformEventType.servicesDiscovered;
    case 'subscriptionsActive':
      return ProtectionPlatformEventType.subscriptionsActive;
    case 'packetReceived':
      return ProtectionPlatformEventType.packetReceived;
    case 'restorationDetected':
      return ProtectionPlatformEventType.restorationDetected;
    case 'restorationRehydrated':
      return ProtectionPlatformEventType.restorationRehydrated;
    case 'bluetoothTurnedOff':
      return ProtectionPlatformEventType.bluetoothTurnedOff;
    case 'bluetoothTurnedOn':
      return ProtectionPlatformEventType.bluetoothTurnedOn;
    case 'runtimeError':
      return ProtectionPlatformEventType.runtimeError;
    case 'woke':
    default:
      return ProtectionPlatformEventType.woke;
  }
}

ProtectionPlatformEventType parseAndroidProtectionPlatformEventType(
  String? value,
) {
  switch (value) {
    case 'serviceStarted':
      return ProtectionPlatformEventType.serviceStarted;
    case 'serviceStopped':
      return ProtectionPlatformEventType.serviceStopped;
    case 'serviceRestarted':
      return ProtectionPlatformEventType.serviceRestarted;
    case 'runtimeStarting':
      return ProtectionPlatformEventType.runtimeStarting;
    case 'runtimeStarted':
      return ProtectionPlatformEventType.runtimeStarted;
    case 'runtimeActive':
      return ProtectionPlatformEventType.runtimeActive;
    case 'runtimeStopped':
      return ProtectionPlatformEventType.runtimeStopped;
    case 'runtimeRecovered':
      return ProtectionPlatformEventType.runtimeRecovered;
    case 'runtimeRestarted':
      return ProtectionPlatformEventType.runtimeRestarted;
    case 'runtimeFailed':
      return ProtectionPlatformEventType.runtimeFailed;
    case 'deviceConnecting':
      return ProtectionPlatformEventType.deviceConnecting;
    case 'deviceConnected':
      return ProtectionPlatformEventType.deviceConnected;
    case 'deviceDisconnected':
      return ProtectionPlatformEventType.deviceDisconnected;
    case 'reconnectScheduled':
      return ProtectionPlatformEventType.reconnectScheduled;
    case 'reconnectFailed':
      return ProtectionPlatformEventType.reconnectFailed;
    case 'servicesDiscovered':
      return ProtectionPlatformEventType.servicesDiscovered;
    case 'subscriptionsActive':
      return ProtectionPlatformEventType.subscriptionsActive;
    case 'packetReceived':
      return ProtectionPlatformEventType.packetReceived;
    case 'sosEventReceived':
      return ProtectionPlatformEventType.sosEventReceived;
    case 'runtimeError':
      return ProtectionPlatformEventType.runtimeError;
    case 'restorationDetected':
      return ProtectionPlatformEventType.restorationDetected;
    case 'restorationRehydrated':
      return ProtectionPlatformEventType.restorationRehydrated;
    case 'nativeBackendSyncQueued':
      return ProtectionPlatformEventType.nativeBackendSyncQueued;
    case 'nativeBackendSyncSucceeded':
      return ProtectionPlatformEventType.nativeBackendSyncSucceeded;
    case 'nativeBackendSyncFailed':
      return ProtectionPlatformEventType.nativeBackendSyncFailed;
    case 'bluetoothTurnedOff':
      return ProtectionPlatformEventType.bluetoothTurnedOff;
    case 'bluetoothTurnedOn':
      return ProtectionPlatformEventType.bluetoothTurnedOn;
    case 'woke':
    default:
      return ProtectionPlatformEventType.woke;
  }
}

ProtectionRuntimeState parseProtectionRuntimeState(String? value) {
  switch (value) {
    case 'starting':
      return ProtectionRuntimeState.starting;
    case 'active':
      return ProtectionRuntimeState.active;
    case 'recovering':
      return ProtectionRuntimeState.recovering;
    case 'failed':
      return ProtectionRuntimeState.failed;
    case 'inactive':
    default:
      return ProtectionRuntimeState.inactive;
  }
}

ProtectionCoverageLevel parseProtectionCoverageLevel(String? value) {
  switch (value) {
    case 'partial':
      return ProtectionCoverageLevel.partial;
    case 'full':
      return ProtectionCoverageLevel.full;
    case 'none':
    default:
      return ProtectionCoverageLevel.none;
  }
}

ProtectionCapabilityState parseProtectionCapabilityState(String? value) {
  switch (value) {
    case 'configured':
      return ProtectionCapabilityState.configured;
    case 'unavailable':
      return ProtectionCapabilityState.unavailable;
    case 'unknown':
    default:
      return ProtectionCapabilityState.unknown;
  }
}

ProtectionBleOwner parseProtectionBleOwner(String? value) {
  switch (value) {
    case 'iosPlugin':
      return ProtectionBleOwner.iosPlugin;
    case 'androidService':
      return ProtectionBleOwner.androidService;
    case 'flutter':
    default:
      return ProtectionBleOwner.flutter;
  }
}

DateTime? readProtectionPlatformDateTime(Object? value) {
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }
  if (value is String && value.trim().isNotEmpty) {
    return DateTime.tryParse(value)?.toUtc();
  }
  return null;
}
