import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

/// Platform-backed permission repository.
///
/// It centralises all permission requests used by the SDK and exposes a single
/// [PermissionState] snapshot that host apps can query at any time.
class PlatformPermissionsRepository implements PermissionsRepository {
  PermissionState _state = const PermissionState();

  @override
  Future<PermissionState> getPermissionState() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    final locationPermission = await Geolocator.checkPermission();
    final notificationPermission = await ph.Permission.notification.status;
    final bluetoothState = await _getBluetoothPermissionState();

    _state = PermissionState(
      location: serviceEnabled
          ? _mapLocationPermission(locationPermission)
          : SdkPermissionStatus.serviceDisabled,
      notifications: _mapPermissionStatus(notificationPermission),
      bluetooth: bluetoothState.$1,
      bluetoothEnabled: bluetoothState.$2,
    );
    return _state;
  }

  @override
  Future<PermissionState> requestLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _state = _state.copyWith(location: SdkPermissionStatus.serviceDisabled);
      return _state;
    }

    final permission = await Geolocator.requestPermission();
    _state = _state.copyWith(location: _mapLocationPermission(permission));
    return _state;
  }

  @override
  Future<PermissionState> requestNotificationPermission() async {
    final status = await ph.Permission.notification.request();
    _state = _state.copyWith(notifications: _mapPermissionStatus(status));
    return _state;
  }

  @override
  Future<PermissionState> requestBluetoothPermission() async {
    final result = await _requestBluetoothPermissions();
    _state = _state.copyWith(
      bluetooth: result.$1,
      bluetoothEnabled: result.$2,
    );
    return _state;
  }

  Future<(SdkPermissionStatus, bool)> _getBluetoothPermissionState() async {
    final permissions = await _bluetoothPermissions;
    final statuses = <ph.PermissionStatus>[];
    for (final permission in permissions) {
      statuses.add(await permission.status);
    }
    return (_mergeStatuses(statuses), await _isBluetoothEnabled());
  }

  Future<(SdkPermissionStatus, bool)> _requestBluetoothPermissions() async {
    final permissions = await _bluetoothPermissions;
    final statuses = <ph.PermissionStatus>[];
    for (final permission in permissions) {
      statuses.add(await permission.request());
    }
    return (_mergeStatuses(statuses), await _isBluetoothEnabled());
  }

  Future<List<ph.Permission>> get _bluetoothPermissions async {
    if (Platform.isAndroid) {
      return [ph.Permission.bluetoothScan, ph.Permission.bluetoothConnect];
    }
    if (Platform.isIOS) {
      return [ph.Permission.bluetooth];
    }
    return [ph.Permission.bluetooth];
  }

  Future<bool> _isBluetoothEnabled() async {
    try {
      return await ph.Permission.bluetooth.serviceStatus.isEnabled;
    } catch (_) {
      return false;
    }
  }

  SdkPermissionStatus _mapLocationPermission(LocationPermission permission) {
    switch (permission) {
      case LocationPermission.always:
      case LocationPermission.whileInUse:
        return SdkPermissionStatus.granted;
      case LocationPermission.denied:
        return SdkPermissionStatus.denied;
      case LocationPermission.deniedForever:
        return SdkPermissionStatus.permanentlyDenied;
      case LocationPermission.unableToDetermine:
        return SdkPermissionStatus.unknown;
    }
  }

  SdkPermissionStatus _mergeStatuses(List<ph.PermissionStatus> statuses) {
    if (statuses.isEmpty) return SdkPermissionStatus.unknown;
    if (statuses.any((status) => status.isPermanentlyDenied)) {
      return SdkPermissionStatus.permanentlyDenied;
    }
    if (statuses.any((status) => status.isRestricted)) {
      return SdkPermissionStatus.restricted;
    }
    if (statuses.any((status) => status.isDenied)) {
      return SdkPermissionStatus.denied;
    }
    if (statuses.any((status) => status.isLimited)) {
      return SdkPermissionStatus.limited;
    }
    if (statuses.every((status) => status.isGranted)) {
      return SdkPermissionStatus.granted;
    }
    return SdkPermissionStatus.unknown;
  }

  SdkPermissionStatus _mapPermissionStatus(ph.PermissionStatus status) {
    if (status.isGranted) return SdkPermissionStatus.granted;
    if (status.isPermanentlyDenied)
      return SdkPermissionStatus.permanentlyDenied;
    if (status.isRestricted) return SdkPermissionStatus.restricted;
    if (status.isLimited) return SdkPermissionStatus.limited;
    if (status.isDenied) return SdkPermissionStatus.denied;
    return SdkPermissionStatus.unknown;
  }
}
