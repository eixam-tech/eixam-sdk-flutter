import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart'
    as permission_handler;

class AndroidProtectionPlatformAdapter implements ProtectionPlatformAdapter {
  AndroidProtectionPlatformAdapter({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    Stream<dynamic> Function()? eventStreamFactory,
  })  : _methodChannel = methodChannel ??
            const MethodChannel(_methodChannelName),
        _eventChannel = eventChannel ?? const EventChannel(_eventChannelName),
        _eventStreamFactory = eventStreamFactory;

  static const String _methodChannelName =
      'com.example.eixam_control_app/protection_runtime/methods';
  static const String _eventChannelName =
      'com.example.eixam_control_app/protection_runtime/events';

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
      foregroundServiceConfigured:
          snapshot['foregroundServiceConfigured'] as bool? ?? false,
      serviceRunning: snapshot['serviceRunning'] as bool? ?? false,
      runtimeActive: snapshot['runtimeActive'] as bool? ?? false,
      bluetoothEnabled: snapshot['bluetoothEnabled'] as bool?,
      notificationsGranted: snapshot['notificationsGranted'] as bool?,
      lastFailureReason: snapshot['lastFailureReason'] as String?,
      lastPlatformEvent: snapshot['lastPlatformEvent'] as String?,
      lastPlatformEventAt: _readDateTime(snapshot['lastPlatformEventAt']),
      runtimeState: _parseRuntimeState(
        snapshot['runtimeState'] as String?,
      ),
      coverageLevel: _parseCoverageLevel(
        snapshot['coverageLevel'] as String?,
      ),
      lastWakeAt: _readDateTime(snapshot['lastWakeAt']),
      lastWakeReason: snapshot['lastWakeReason'] as String?,
    );
  }

  @override
  Future<ProtectionPlatformStartResult> startProtectionRuntime() async {
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
  Future<void> openProtectionSettings() async {
    await permission_handler.openAppSettings();
  }

  @override
  Stream<ProtectionPlatformEvent> watchPlatformEvents() {
    return _events ??= (_eventStreamFactory?.call() ??
            _eventChannel.receiveBroadcastStream())
        .map((dynamic event) {
          final data = Map<Object?, Object?>.from(
            event as Map<Object?, Object?>,
          );
          return ProtectionPlatformEvent(
            type: _parseEventType(data['type'] as String?),
            timestamp: _readDateTime(data['timestamp']) ?? DateTime.now().toUtc(),
            reason: data['reason'] as String?,
          );
        })
        .asBroadcastStream();
  }

  ProtectionPlatformEventType _parseEventType(String? value) {
    switch (value) {
      case 'runtimeStarted':
        return ProtectionPlatformEventType.runtimeStarted;
      case 'runtimeStopped':
        return ProtectionPlatformEventType.runtimeStopped;
      case 'runtimeRecovered':
        return ProtectionPlatformEventType.runtimeRecovered;
      case 'runtimeRestarted':
        return ProtectionPlatformEventType.runtimeRestarted;
      case 'runtimeFailed':
        return ProtectionPlatformEventType.runtimeFailed;
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
