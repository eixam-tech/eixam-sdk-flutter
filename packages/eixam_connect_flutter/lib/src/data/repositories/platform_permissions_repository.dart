import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../../device/ble_adapter_state.dart';
import '../../device/ble_client.dart';

/// Platform-backed permission repository.
///
/// It centralises all permission requests used by the SDK and exposes a single
/// [PermissionState] snapshot that host apps can query at any time.
class PlatformPermissionsRepository implements PermissionsRepository {
  PlatformPermissionsRepository({
    Object? bleClient,
    Future<bool> Function()? locationServiceEnabledProvider,
    Future<LocationPermission> Function()? locationPermissionProvider,
    Future<ph.PermissionStatus> Function()? notificationPermissionProvider,
    Future<List<ph.PermissionStatus>> Function()? bluetoothStatusesProvider,
    Future<bool> Function()? bluetoothServiceEnabledProvider,
    bool Function()? isAndroidPlatform,
    bool Function()? isIosPlatform,
  })  : _bleClient = bleClient is BleClient ? bleClient : null,
        _locationServiceEnabledProvider = locationServiceEnabledProvider ??
            Geolocator.isLocationServiceEnabled,
        _locationPermissionProvider =
            locationPermissionProvider ?? Geolocator.checkPermission,
        _notificationPermissionProvider = notificationPermissionProvider ??
            (() => ph.Permission.notification.status),
        _bluetoothStatusesProvider = bluetoothStatusesProvider,
        _bluetoothServiceEnabledProvider = bluetoothServiceEnabledProvider,
        _isAndroidPlatform = isAndroidPlatform ?? (() => Platform.isAndroid),
        _isIosPlatform = isIosPlatform ?? (() => Platform.isIOS);

  final BleClient? _bleClient;
  final Future<bool> Function() _locationServiceEnabledProvider;
  final Future<LocationPermission> Function() _locationPermissionProvider;
  final Future<ph.PermissionStatus> Function() _notificationPermissionProvider;
  final Future<List<ph.PermissionStatus>> Function()?
      _bluetoothStatusesProvider;
  final Future<bool> Function()? _bluetoothServiceEnabledProvider;
  final bool Function() _isAndroidPlatform;
  final bool Function() _isIosPlatform;

  PermissionState _state = const PermissionState();

  @override
  Future<PermissionState> getPermissionState() async {
    final serviceEnabled = await _locationServiceEnabledProvider();
    final locationPermission = await _locationPermissionProvider();
    final notificationPermission = await _notificationPermissionProvider();
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
    final statuses = await _readBluetoothPermissionStatuses();
    final permissionStatus = _mergeStatuses(statuses);
    final serviceEnabled = await _isBluetoothEnabled();
    return _resolveBluetoothPermissionState(
      permissionStatus: permissionStatus,
      serviceEnabled: serviceEnabled,
    );
  }

  Future<(SdkPermissionStatus, bool)> _requestBluetoothPermissions() async {
    final permissions = await _bluetoothPermissions;
    final statuses = <ph.PermissionStatus>[];
    for (final permission in permissions) {
      statuses.add(await permission.request());
    }
    return _resolveBluetoothPermissionState(
      permissionStatus: _mergeStatuses(statuses),
      serviceEnabled: await _isBluetoothEnabled(),
    );
  }

  Future<List<ph.Permission>> get _bluetoothPermissions async {
    if (_isAndroidPlatform()) {
      return [ph.Permission.bluetoothScan, ph.Permission.bluetoothConnect];
    }
    if (_isIosPlatform()) {
      return [ph.Permission.bluetooth];
    }
    return [ph.Permission.bluetooth];
  }

  Future<List<ph.PermissionStatus>> _readBluetoothPermissionStatuses() async {
    final provider = _bluetoothStatusesProvider;
    if (provider != null) {
      return provider();
    }
    final permissions = await _bluetoothPermissions;
    final statuses = <ph.PermissionStatus>[];
    for (final permission in permissions) {
      statuses.add(await permission.status);
    }
    return statuses;
  }

  Future<bool> _isBluetoothEnabled() async {
    final provider = _bluetoothServiceEnabledProvider;
    if (provider != null) {
      return provider();
    }
    try {
      return await ph.Permission.bluetooth.serviceStatus.isEnabled;
    } catch (_) {
      return false;
    }
  }

  Future<(SdkPermissionStatus, bool)> _resolveBluetoothPermissionState({
    required SdkPermissionStatus permissionStatus,
    required bool serviceEnabled,
  }) async {
    if (!_isIosPlatform()) {
      return (permissionStatus, serviceEnabled);
    }
    final adapterState = await _readBleAdapterState();
    return switch (adapterState) {
      BleAdapterState.poweredOn => (SdkPermissionStatus.granted, true),
      BleAdapterState.poweredOff => (SdkPermissionStatus.granted, false),
      BleAdapterState.unauthorized => (
          SdkPermissionStatus.permanentlyDenied,
          false,
        ),
      BleAdapterState.unsupported => (SdkPermissionStatus.restricted, false),
      BleAdapterState.unknown || null => (permissionStatus, serviceEnabled),
    };
  }

  Future<BleAdapterState?> _readBleAdapterState() async {
    final bleClient = _bleClient;
    if (bleClient == null) {
      return null;
    }
    try {
      return await bleClient.getAdapterState();
    } catch (_) {
      return null;
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
    if (status.isPermanentlyDenied) {
      return SdkPermissionStatus.permanentlyDenied;
    }
    if (status.isRestricted) return SdkPermissionStatus.restricted;
    if (status.isLimited) return SdkPermissionStatus.limited;
    if (status.isDenied) return SdkPermissionStatus.denied;
    return SdkPermissionStatus.unknown;
  }
}
