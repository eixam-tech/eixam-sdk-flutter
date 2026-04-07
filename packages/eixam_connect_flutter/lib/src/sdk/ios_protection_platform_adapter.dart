import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart'
    as permission_handler;

import 'protection_platform_channel_mapper.dart';
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
  ProtectionPlatform get platform => ProtectionPlatform.ios;

  @override
  Future<ProtectionPlatformSnapshot> getPlatformSnapshot() async {
    final raw = await _methodChannel.invokeMapMethod<String, dynamic>(
      'getPlatformSnapshot',
    );
    return mapIosProtectionPlatformSnapshot(raw ?? const <String, dynamic>{});
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
    return const ProtectionPlatformFlushResult();
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
      return mapIosProtectionPlatformEvent(data);
    }).asBroadcastStream();
  }
}
