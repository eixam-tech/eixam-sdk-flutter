import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/services.dart';

/// Android-specific request capabilities around the shared location snapshot.
/// Permission grants are always read from the OS, never persisted here.
class AndroidLocationPermissionState {
  const AndroidLocationPermissionState({
    required this.permission,
    required this.apiLevel,
    required this.foregroundRequestAvailable,
    required this.backgroundRequestAvailable,
    this.backgroundPermissionOptionLabel,
  });

  final LocationPermissionSnapshot permission;
  final int apiLevel;
  final bool foregroundRequestAvailable;
  final bool backgroundRequestAvailable;
  final String? backgroundPermissionOptionLabel;

  bool get settingsRequired =>
      !permission.isBackgroundLocationUsable &&
      (permission.isForegroundLocationUsable
          ? !backgroundRequestAvailable
          : !foregroundRequestAvailable);

  /// Android does not expose a reliable public API for an ordinary app to
  /// distinguish a one-time foreground grant from a while-in-use grant.
  /// Neither is represented as permanent/background readiness.
  bool? get temporarilyGranted => null;
}

/// Explicit Android location actions. Construction and reads never prompt.
/// Hosts must explain the active feature before requesting background access.
/// Request futures complete with fresh OS truth after native UI returns.
class AndroidLocationPermissions {
  AndroidLocationPermissions({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel('dev.eixam.connect_flutter/location_permissions');

  final MethodChannel _channel;
  Future<AndroidLocationPermissionState>? _request;
  String? _requestMethod;

  Future<AndroidLocationPermissionState> getState() => _invoke('getState');

  Future<AndroidLocationPermissionState> requestForeground() =>
      _requestOnce('requestForeground');

  /// Requires foreground first. API 29 uses the runtime dialog; API 30+ uses
  /// the separate runtime request when available, otherwise app details.
  /// Denial never triggers a second prompt or a Settings redirect.
  Future<AndroidLocationPermissionState> requestBackground() =>
      _requestOnce('requestBackground');

  Future<AndroidLocationPermissionState> _requestOnce(String method) {
    final pending = _request;
    if (pending != null) {
      if (_requestMethod == method) return pending;
      return Future.error(
        StateError('Another location permission action is active'),
      );
    }
    _requestMethod = method;
    return _request = _invoke(method).whenComplete(() {
      _request = null;
      _requestMethod = null;
    });
  }

  Future<AndroidLocationPermissionState> _invoke(String method) async {
    final raw = await _channel.invokeMapMethod<String, dynamic>(method);
    if (raw == null) {
      throw const FormatException('Missing Android location permission state');
    }
    final foreground = raw['foregroundGranted'] as bool;
    final background = raw['backgroundGranted'] as bool;
    final precise = raw['preciseGranted'] as bool;
    return AndroidLocationPermissionState(
      apiLevel: raw['apiLevel'] as int,
      permission: LocationPermissionSnapshot(
        locationServicesEnabled: raw['locationServicesEnabled'] as bool,
        authorizationStatus: background
            ? LocationAuthorizationStatus.always
            : foreground
            ? LocationAuthorizationStatus.whenInUse
            : raw['foregroundRequested'] == true
            ? LocationAuthorizationStatus.denied
            : LocationAuthorizationStatus.notDetermined,
        accuracyAuthorization: !foreground
            ? LocationAccuracyAuthorization.unknown
            : precise
            ? LocationAccuracyAuthorization.full
            : LocationAccuracyAuthorization.reduced,
      ),
      foregroundRequestAvailable: raw['foregroundRequestAvailable'] as bool,
      backgroundRequestAvailable: raw['backgroundRequestAvailable'] as bool,
      backgroundPermissionOptionLabel:
          raw['backgroundPermissionOptionLabel'] as String?,
    );
  }
}
