import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart'
    as permission_handler;

import 'protection_platform_channel_mapper.dart';
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
    return mapAndroidProtectionPlatformSnapshot(raw ?? const <String, dynamic>{});
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
    return mapProtectionPlatformStartResult(raw ?? const <String, dynamic>{});
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
    return mapProtectionPlatformFlushResult(raw ?? const <String, dynamic>{});
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
    return mapProtectionPlatformCommandResult(raw ?? const <String, dynamic>{});
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
      return mapAndroidProtectionPlatformEvent(data);
    }).asBroadcastStream();
  }
}
