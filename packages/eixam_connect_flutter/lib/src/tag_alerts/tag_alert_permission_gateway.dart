import 'dart:io' show Platform;

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

/// Notification permission access for the TAG alerts capability.
abstract interface class TagAlertPermissionGateway {
  /// Never prompts.
  Future<TagAlertPermissionState> state();

  /// Prompts when the OS allows it.
  Future<TagAlertPermissionState> request();
}

/// Gateway for runtimes without notification support.
final class UnsupportedTagAlertPermissionGateway
    implements TagAlertPermissionGateway {
  const UnsupportedTagAlertPermissionGateway();

  @override
  Future<TagAlertPermissionState> state() async =>
      TagAlertPermissionState.unsupported;

  @override
  Future<TagAlertPermissionState> request() async =>
      TagAlertPermissionState.unsupported;
}

/// Default gateway.
///
/// Android: `areNotificationsEnabled()` for the passive state (granted or
/// denied); `request()` uses the runtime permission and is the only call that
/// can report `permanentlyDenied`, because `status` is unreliable for it.
/// iOS: `permission_handler` distinguishes "not asked yet" from "declined".
final class PlatformTagAlertPermissionGateway
    implements TagAlertPermissionGateway {
  PlatformTagAlertPermissionGateway({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  @override
  Future<TagAlertPermissionState> state() async {
    if (Platform.isAndroid) {
      final enabled = await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.areNotificationsEnabled();
      if (enabled == null) return TagAlertPermissionState.unsupported;
      return enabled
          ? TagAlertPermissionState.granted
          : TagAlertPermissionState.denied;
    }
    if (Platform.isIOS) {
      return statusToState(await Permission.notification.status);
    }
    return TagAlertPermissionState.unsupported;
  }

  @override
  Future<TagAlertPermissionState> request() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return TagAlertPermissionState.unsupported;
    }
    final status = await Permission.notification.request();
    if (Platform.isAndroid) {
      if (status.isGranted) return TagAlertPermissionState.granted;
      return status.isPermanentlyDenied
          ? TagAlertPermissionState.permanentlyDenied
          : TagAlertPermissionState.denied;
    }
    return statusToState(status);
  }

  // permission_handler iOS: `denied` = not determined, `permanentlyDenied` =
  // declined (or restricted).
  @visibleForTesting
  static TagAlertPermissionState statusToState(PermissionStatus status) {
    if (status.isGranted || status.isLimited || status.isProvisional) {
      return TagAlertPermissionState.granted;
    }
    if (status.isPermanentlyDenied || status.isRestricted) {
      return TagAlertPermissionState.permanentlyDenied;
    }
    return TagAlertPermissionState.notDetermined;
  }
}
