import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart'
    as permission_handler;

import 'protection_platform_adapter.dart';

class IosProtectionPlatformAdapter implements ProtectionPlatformAdapter {
  IosProtectionPlatformAdapter({
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
      serviceRunning: false,
      runtimeActive: snapshot['runtimeActive'] as bool? ?? false,
      bluetoothEnabled: snapshot['bluetoothEnabled'] as bool?,
      notificationsGranted: snapshot['notificationsGranted'] as bool?,
      lastFailureReason: snapshot['lastFailureReason'] as String?,
      lastPlatformEvent: snapshot['lastPlatformEvent'] as String?,
      lastPlatformEventAt: _readDateTime(snapshot['lastPlatformEventAt']),
      runtimeState: _parseRuntimeState(snapshot['runtimeState'] as String?),
      coverageLevel: _parseCoverageLevel(snapshot['coverageLevel'] as String?),
      platform: ProtectionPlatform.ios,
      backgroundCapabilityState: _parseCapabilityState(
        snapshot['backgroundCapabilityState'] as String?,
      ),
      restorationConfigured:
          snapshot['restorationConfigured'] as bool? ?? false,
      bleOwner: ProtectionBleOwner.flutter,
      pendingSosCount: snapshot['pendingSosCount'] as int? ?? 0,
      pendingTelemetryCount: snapshot['pendingTelemetryCount'] as int? ?? 0,
      lastRestorationEvent: snapshot['lastRestorationEvent'] as String?,
      lastRestorationEventAt: _readDateTime(snapshot['lastRestorationEventAt']),
      degradationReason: snapshot['degradationReason'] as String?,
    );
  }

  @override
  Future<ProtectionPlatformStartResult> startProtectionRuntime({
    required ProtectionPlatformStartRequest request,
  }) async {
    final raw = await _methodChannel.invokeMapMethod<String, dynamic>(
      'startProtectionRuntime',
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
  Future<ProtectionPlatformFlushResult> flushProtectionQueues() async {
    return const ProtectionPlatformFlushResult();
  }

  @override
  Future<ProtectionPermissionResult> requestProtectionPermissions() async {
    final statuses = await <permission_handler.Permission>[
      permission_handler.Permission.notification,
      permission_handler.Permission.bluetooth,
      permission_handler.Permission.locationWhenInUse,
    ].request();
    return ProtectionPermissionResult(
      locationGranted: statuses[permission_handler.Permission.locationWhenInUse]
                  ?.isGranted ==
              true ||
          statuses[permission_handler.Permission.locationWhenInUse]
                  ?.isLimited ==
              true,
      notificationsGranted:
          statuses[permission_handler.Permission.notification]?.isGranted ==
              true,
      bluetoothGranted:
          statuses[permission_handler.Permission.bluetooth]?.isGranted == true,
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
      case 'restorationDetected':
        return ProtectionPlatformEventType.restorationDetected;
      case 'restorationRehydrated':
        return ProtectionPlatformEventType.restorationRehydrated;
      case 'runtimeError':
        return ProtectionPlatformEventType.runtimeError;
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
