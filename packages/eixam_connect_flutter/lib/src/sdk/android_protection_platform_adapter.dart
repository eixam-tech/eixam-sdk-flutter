import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart'
    as permission_handler;

import 'protection_platform_adapter.dart';

class AndroidProtectionPlatformAdapter implements ProtectionPlatformAdapter {
  AndroidProtectionPlatformAdapter({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    Stream<dynamic> Function()? eventStreamFactory,
  })  : _methodChannel =
            methodChannel ?? const MethodChannel(_methodChannelName),
        _eventChannel = eventChannel ?? const EventChannel(_eventChannelName),
        _eventStreamFactory = eventStreamFactory;

  static const String _methodChannelName =
      'dev.eixam.connect_flutter/protection_runtime/methods';
  static const String _eventChannelName =
      'dev.eixam.connect_flutter/protection_runtime/events';

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final Stream<dynamic> Function()? _eventStreamFactory;

  Stream<ProtectionPlatformEvent>? _events;

  @override
  ProtectionPlatform get platform => ProtectionPlatform.android;

  @override
  Future<ProtectionPlatformSnapshot> getPlatformSnapshot() async {
    final raw = await _methodChannel.invokeMapMethod<String, dynamic>(
      'getPlatformSnapshot',
    );
    final snapshot = raw ?? const <String, dynamic>{};
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
      lastPlatformEventAt: _readDateTime(snapshot['lastPlatformEventAt']),
      runtimeState: _parseRuntimeState(snapshot['runtimeState'] as String?),
      coverageLevel: _parseCoverageLevel(snapshot['coverageLevel'] as String?),
      lastWakeAt: _readDateTime(snapshot['lastWakeAt']),
      lastWakeReason: snapshot['lastWakeReason'] as String?,
      platform: ProtectionPlatform.android,
      backgroundCapabilityState: _parseCapabilityState(
        snapshot['backgroundCapabilityState'] as String?,
      ),
      restorationConfigured:
          snapshot['restorationConfigured'] as bool? ?? false,
      bleOwner: _parseBleOwner(snapshot['bleOwner'] as String?),
      serviceBleConnected: snapshot['serviceBleConnected'] as bool? ?? false,
      serviceBleReady: snapshot['serviceBleReady'] as bool? ?? false,
      pendingSosCount: snapshot['pendingSosCount'] as int? ?? 0,
      pendingTelemetryCount: snapshot['pendingTelemetryCount'] as int? ?? 0,
      pendingNativeSosCreateCount:
          snapshot['pendingNativeSosCreateCount'] as int? ?? 0,
      pendingNativeSosCancelCount:
          snapshot['pendingNativeSosCancelCount'] as int? ?? 0,
      lastRestorationEvent: snapshot['lastRestorationEvent'] as String?,
      lastRestorationEventAt: _readDateTime(snapshot['lastRestorationEventAt']),
      lastBleServiceEvent: snapshot['lastBleServiceEvent'] as String?,
      lastBleServiceEventAt: _readDateTime(snapshot['lastBleServiceEventAt']),
      reconnectAttemptCount: snapshot['reconnectAttemptCount'] as int? ?? 0,
      lastReconnectAttemptAt: _readDateTime(snapshot['lastReconnectAttemptAt']),
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
          (snapshot['expectedBleCharacteristicUuids'] as List<dynamic>? ?? const [])
              .map((value) => value.toString())
              .toList(growable: false),
      discoveredBleServicesSummary:
          snapshot['discoveredBleServicesSummary'] as String?,
      readinessFailureReason: snapshot['readinessFailureReason'] as String?,
      nativeBackendBaseUrl: snapshot['nativeBackendBaseUrl'] as String?,
      nativeBackendConfigValid:
          snapshot['nativeBackendConfigValid'] as bool? ?? true,
      nativeBackendConfigIssue:
          snapshot['nativeBackendConfigIssue'] as String?,
      debugLocalhostBackendAllowed:
          snapshot['debugLocalhostBackendAllowed'] as bool? ?? false,
      debugCleartextBackendAllowed:
          snapshot['debugCleartextBackendAllowed'] as bool? ?? false,
      lastCommandRoute: snapshot['lastCommandRoute'] as String?,
      lastCommandResult: snapshot['lastCommandResult'] as String?,
      lastCommandError: snapshot['lastCommandError'] as String?,
    );
  }

  @override
  Future<ProtectionPlatformStartResult> startProtectionRuntime({
    required ProtectionPlatformStartRequest request,
  }) async {
    final raw = await _methodChannel.invokeMapMethod<String, dynamic>(
      'startProtectionRuntime',
      <String, dynamic>{
        'activeDeviceId': request.activeDeviceId,
        'apiBaseUrl': request.apiBaseUrl,
        'sessionReady': request.sessionReady,
        'enableStoreAndForward': request.enableStoreAndForward,
        'autoReconnectBle': request.modeOptions.autoReconnectBle,
        'autoFlushOnReconnect': request.modeOptions.autoFlushOnReconnect,
        'allowDegradedMode': request.modeOptions.allowDegradedMode,
        'reconnectBackoffMs':
            request.modeOptions.reconnectBackoff.inMilliseconds,
        'healthCheckIntervalMs':
            request.modeOptions.healthCheckInterval.inMilliseconds,
      },
    );
    final result = raw ?? const <String, dynamic>{};
    return ProtectionPlatformStartResult(
      success: result['success'] as bool? ?? false,
      runtimeState: _parseRuntimeState(result['runtimeState'] as String?),
      coverageLevel: _parseCoverageLevel(result['coverageLevel'] as String?),
      failureReason: result['failureReason'] as String?,
      statusMessage: result['statusMessage'] as String?,
    );
  }

  @override
  Future<void> stopProtectionRuntime() {
    return _methodChannel.invokeMethod<void>('stopProtectionRuntime');
  }

  @override
  Future<void> ensureProtectionRuntimeActive({
    String reason = 'app_foreground_resume',
  }) {
    return _methodChannel.invokeMethod<void>(
      'resumeProtectionRuntime',
      <String, dynamic>{'reason': reason},
    );
  }

  @override
  Future<ProtectionPlatformFlushResult> flushProtectionQueues() async {
    final raw = await _methodChannel.invokeMapMethod<String, dynamic>(
      'flushProtectionQueues',
    );
    final result = raw ?? const <String, dynamic>{};
    return ProtectionPlatformFlushResult(
      flushedSosCount: result['flushedSosCount'] as int? ?? 0,
      flushedTelemetryCount: result['flushedTelemetryCount'] as int? ?? 0,
      success: result['success'] as bool? ?? true,
    );
  }

  @override
  Future<ProtectionPermissionResult> requestProtectionPermissions() async {
    final statuses = await <permission_handler.Permission>[
      permission_handler.Permission.location,
      permission_handler.Permission.notification,
      permission_handler.Permission.bluetooth,
      permission_handler.Permission.bluetoothScan,
      permission_handler.Permission.bluetoothConnect,
    ].request();

    final bluetoothGranted = <permission_handler.Permission>[
      permission_handler.Permission.bluetooth,
      permission_handler.Permission.bluetoothScan,
      permission_handler.Permission.bluetoothConnect,
    ].every(
      (permission) =>
          statuses[permission]?.isGranted == true ||
          statuses[permission]?.isLimited == true,
    );

    return ProtectionPermissionResult(
      locationGranted:
          statuses[permission_handler.Permission.location]?.isGranted == true ||
              statuses[permission_handler.Permission.location]?.isLimited ==
                  true,
      notificationsGranted:
          statuses[permission_handler.Permission.notification]?.isGranted ==
              true,
      bluetoothGranted: bluetoothGranted,
    );
  }

  @override
  Future<ProtectionPlatformCommandResult> sendProtectionCommand({
    required ProtectionPlatformCommandRequest request,
  }) async {
    final raw = await _methodChannel.invokeMapMethod<String, dynamic>(
      'sendProtectionCommand',
      <String, dynamic>{
        'label': request.label,
        'bytes': request.bytes,
        'forceCmdCharacteristic': request.forceCmdCharacteristic,
      },
    );
    final result = raw ?? const <String, dynamic>{};
    return ProtectionPlatformCommandResult(
      success: result['success'] as bool? ?? false,
      route: result['route'] as String?,
      result: result['result'] as String?,
      error: result['error'] as String?,
    );
  }

  @override
  Future<void> openProtectionSettings() async {
    await permission_handler.openAppSettings();
  }

  @override
  Stream<ProtectionPlatformEvent> watchPlatformEvents() {
    return _events ??=
        (_eventStreamFactory?.call() ?? _eventChannel.receiveBroadcastStream())
            .map((dynamic event) {
      final data = Map<Object?, Object?>.from(
        event as Map<Object?, Object?>,
      );
      return ProtectionPlatformEvent(
        type: _parseEventType(data['type'] as String?),
        timestamp: _readDateTime(data['timestamp']) ?? DateTime.now().toUtc(),
        reason: data['reason'] as String?,
      );
    }).asBroadcastStream();
  }

  ProtectionPlatformEventType _parseEventType(String? value) {
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

  ProtectionRuntimeState _parseRuntimeState(String? value) {
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

  ProtectionCoverageLevel _parseCoverageLevel(String? value) {
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

  ProtectionBleOwner _parseBleOwner(String? value) {
    switch (value) {
      case 'androidService':
        return ProtectionBleOwner.androidService;
      case 'iosPlugin':
        return ProtectionBleOwner.iosPlugin;
      case 'flutter':
      default:
        return ProtectionBleOwner.flutter;
    }
  }

  ProtectionCapabilityState _parseCapabilityState(String? value) {
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

  DateTime? _readDateTime(Object? value) {
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    }
    if (value is String && value.trim().isNotEmpty) {
      return DateTime.tryParse(value)?.toUtc();
    }
    return null;
  }
}
