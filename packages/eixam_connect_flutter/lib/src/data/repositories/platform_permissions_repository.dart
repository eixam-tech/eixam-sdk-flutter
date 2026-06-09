import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../../device/ble_adapter_state.dart';
import '../../device/ble_client.dart';

/// Platform-backed permission repository.
///
/// It centralises all permission requests used by the SDK and exposes a single
/// [PermissionState] snapshot that host apps can query at any time.
class PlatformPermissionsRepository implements PermissionsRepository {
  PlatformPermissionsRepository({BleClient? bleClient})
      : _bleClient = bleClient;

  final BleClient? _bleClient;
  PermissionState _state = const PermissionState();
  IosBluetoothPowerState? _lastIosBluetoothPowerState;

  @override
  Future<PermissionState> getPermissionState() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    final locationPermission = await Geolocator.checkPermission();
    final backgroundLocation = await _getBackgroundLocationPermissionState();
    final notificationState = await _getNotificationPermissionState(
      source: 'check',
    );
    final bluetoothState = await _getBluetoothPermissionState();

    _state = PermissionState(
      location: serviceEnabled
          ? _mapLocationPermission(locationPermission)
          : SdkPermissionStatus.serviceDisabled,
      backgroundLocation: backgroundLocation,
      notifications: notificationState.$1,
      bluetooth: bluetoothState.$1,
      bluetoothEnabled: bluetoothState.$2,
      iosBluetoothAuthorization: bluetoothState.$3,
      iosBluetoothPowerState: bluetoothState.$4,
      iosLocationAuthorization:
          _mapIosLocationAuthorization(locationPermission),
      locationServicesEnabled: serviceEnabled,
      iosNotificationAuthorization: notificationState.$2,
    );
    _logIosState(
      bluetoothAuthorization: bluetoothState.$3,
      bluetoothPowerState: bluetoothState.$4,
      locationAuthorization: _state.iosLocationAuthorization,
      locationServicesEnabled: serviceEnabled,
      notificationAuthorization: notificationState.$2,
      source: 'check',
    );
    return _state;
  }

  @override
  Future<PermissionState> requestLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _state = _state.copyWith(
        location: SdkPermissionStatus.serviceDisabled,
        locationServicesEnabled: false,
      );
      _logIosPermissionRequest(type: 'location', result: _state.location.name);
      return _state;
    }

    final permission = await Geolocator.requestPermission();
    _state = _state.copyWith(
      location: _mapLocationPermission(permission),
      iosLocationAuthorization: _mapIosLocationAuthorization(permission),
      locationServicesEnabled: serviceEnabled,
    );
    _logIosPermissionRequest(type: 'location', result: _state.location.name);
    return _state;
  }

  @override
  Future<PermissionState> requestNotificationPermission() async {
    final before = await _getNotificationPermissionState(
      source: 'request_before',
    );
    await ph.Permission.notification.request();
    final after = await _getNotificationPermissionState(
      source: 'request_after',
    );
    _state = _state.copyWith(
      notifications: after.$1,
      iosNotificationAuthorization: after.$2,
    );
    _logIosPermissionRequest(
      type: 'notifications',
      result: _state.notifications.name,
    );
    if (Platform.isIOS) {
      debugPrint(
        'IOS_NOTIFICATION_REFRESH before=${before.$2.name} '
        'after=${after.$2.name} source=sdk_request',
      );
    }
    return _state;
  }

  @override
  Future<PermissionState> requestBluetoothPermission() async {
    final result = await _requestBluetoothPermissions();
    _state = _state.copyWith(
      bluetooth: result.$1,
      bluetoothEnabled: result.$2,
      iosBluetoothAuthorization: result.$3,
      iosBluetoothPowerState: result.$4,
    );
    _logIosPermissionRequest(type: 'bluetooth', result: _state.bluetooth.name);
    return _state;
  }

  Future<
      (
        SdkPermissionStatus,
        bool,
        IosBluetoothAuthorizationStatus,
        IosBluetoothPowerState
      )> _getBluetoothPermissionState() async {
    final permissions = await _bluetoothPermissions;
    final statuses = <ph.PermissionStatus>[];
    for (final permission in permissions) {
      statuses.add(await permission.status);
    }
    final rawPermission = _mergeStatuses(statuses);
    final rawAuthorization = _mapIosBluetoothAuthorization(statuses);
    final bluetoothPower = await _resolveBluetoothPowerState(
      authorization: rawAuthorization,
      source: 'check',
    );
    final effective = _resolveEffectiveIosBluetoothAccess(
      rawPermission: rawPermission,
      rawAuthorization: rawAuthorization,
      powerState: bluetoothPower.$2,
      powered: bluetoothPower.$1,
      source: 'check',
    );
    return (
      effective.$1,
      effective.$2,
      effective.$3,
      bluetoothPower.$2,
    );
  }

  Future<
      (
        SdkPermissionStatus,
        bool,
        IosBluetoothAuthorizationStatus,
        IosBluetoothPowerState
      )> _requestBluetoothPermissions() async {
    if (Platform.isIOS) {
      final current = await _getBluetoothPermissionState();
      if (current.$4 == IosBluetoothPowerState.poweredOn) {
        debugPrint(
          'IOS_BLE_REQUEST_SKIPPED reason=adapter_powered_on source=sdk',
        );
        return current;
      }
    }
    final permissions = await _bluetoothPermissions;
    final statuses = <ph.PermissionStatus>[];
    for (final permission in permissions) {
      statuses.add(await permission.request());
    }
    final rawPermission = _mergeStatuses(statuses);
    final rawAuthorization = _mapIosBluetoothAuthorization(statuses);
    final bluetoothPower = await _resolveBluetoothPowerState(
      authorization: rawAuthorization,
      source: 'request',
    );
    final effective = _resolveEffectiveIosBluetoothAccess(
      rawPermission: rawPermission,
      rawAuthorization: rawAuthorization,
      powerState: bluetoothPower.$2,
      powered: bluetoothPower.$1,
      source: 'request',
    );
    return (
      effective.$1,
      effective.$2,
      effective.$3,
      bluetoothPower.$2,
    );
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

  Future<(bool, IosBluetoothPowerState)> _resolveBluetoothPowerState({
    required IosBluetoothAuthorizationStatus authorization,
    required String source,
  }) async {
    if (!Platform.isIOS) {
      return (await _isBluetoothEnabled(), IosBluetoothPowerState.unknown);
    }
    final permissionServiceEnabled = await _isBluetoothEnabled();
    final adapterState = await _readBleAdapterState();
    final powerState = _mapBleAdapterPowerState(adapterState);
    final resolvedPowered = switch (powerState) {
      IosBluetoothPowerState.poweredOn => true,
      IosBluetoothPowerState.poweredOff ||
      IosBluetoothPowerState.unauthorized ||
      IosBluetoothPowerState.unsupported =>
        false,
      IosBluetoothPowerState.unknown => permissionServiceEnabled,
    };
    final adapterStateLabel = adapterState?.name ?? 'unknown';
    debugPrint(
      'IOS_BLUETOOTH_STATE_SOURCE authorization=${authorization.name} '
      'permissionService=$permissionServiceEnabled '
      'adapterState=$adapterStateLabel '
      'resolvedPowered=$resolvedPowered source=$source',
    );
    final last = _lastIosBluetoothPowerState;
    if (last != null && last != powerState) {
      debugPrint(
        'IOS_BLUETOOTH_POWERED_REFRESH old=${last.name} '
        'new=${powerState.name} source=$source',
      );
    }
    _lastIosBluetoothPowerState = powerState;
    return (resolvedPowered, powerState);
  }

  Future<BleAdapterState?> _readBleAdapterState() async {
    try {
      return await _bleClient?.getAdapterState();
    } catch (_) {
      return null;
    }
  }

  Future<SdkPermissionStatus> _getBackgroundLocationPermissionState() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return SdkPermissionStatus.unknown;
    }
    final status = await ph.Permission.locationAlways.status;
    return _mapPermissionStatus(status);
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
    if (status.isProvisional) return SdkPermissionStatus.limited;
    if (status.isDenied) return SdkPermissionStatus.denied;
    return SdkPermissionStatus.unknown;
  }

  IosBluetoothAuthorizationStatus _mapIosBluetoothAuthorization(
    List<ph.PermissionStatus> statuses,
  ) {
    if (!Platform.isIOS) return IosBluetoothAuthorizationStatus.unknown;
    if (statuses.isEmpty) return IosBluetoothAuthorizationStatus.unknown;
    if (statuses.any((status) => status.isRestricted)) {
      return IosBluetoothAuthorizationStatus.restricted;
    }
    if (statuses.any((status) => status.isPermanentlyDenied)) {
      return IosBluetoothAuthorizationStatus.denied;
    }
    if (statuses.every((status) => status.isGranted || status.isLimited)) {
      return IosBluetoothAuthorizationStatus.allowed;
    }
    if (statuses.any((status) => status.isDenied)) {
      return IosBluetoothAuthorizationStatus.notDetermined;
    }
    return IosBluetoothAuthorizationStatus.unknown;
  }

  IosBluetoothPowerState _mapBleAdapterPowerState(BleAdapterState? state) {
    return switch (state) {
      BleAdapterState.poweredOn => IosBluetoothPowerState.poweredOn,
      BleAdapterState.poweredOff => IosBluetoothPowerState.poweredOff,
      BleAdapterState.unauthorized => IosBluetoothPowerState.unauthorized,
      BleAdapterState.unsupported => IosBluetoothPowerState.unsupported,
      BleAdapterState.unknown || null => IosBluetoothPowerState.unknown,
    };
  }

  (SdkPermissionStatus, bool, IosBluetoothAuthorizationStatus)
      _resolveEffectiveIosBluetoothAccess({
    required SdkPermissionStatus rawPermission,
    required IosBluetoothAuthorizationStatus rawAuthorization,
    required IosBluetoothPowerState powerState,
    required bool powered,
    required String source,
  }) {
    if (!Platform.isIOS) {
      return (rawPermission, powered, rawAuthorization);
    }

    final effectivePermission = switch (powerState) {
      IosBluetoothPowerState.poweredOn => SdkPermissionStatus.granted,
      IosBluetoothPowerState.unauthorized =>
        SdkPermissionStatus.permanentlyDenied,
      IosBluetoothPowerState.poweredOff => SdkPermissionStatus.granted,
      IosBluetoothPowerState.unsupported => SdkPermissionStatus.serviceDisabled,
      IosBluetoothPowerState.unknown => SdkPermissionStatus.unknown,
    };
    final effectiveAuthorization = switch (powerState) {
      IosBluetoothPowerState.poweredOn =>
        IosBluetoothAuthorizationStatus.allowed,
      IosBluetoothPowerState.unauthorized =>
        IosBluetoothAuthorizationStatus.denied,
      _ => rawAuthorization,
    };
    final effectiveReady = powerState == IosBluetoothPowerState.poweredOn ||
        (effectivePermission == SdkPermissionStatus.granted && powered);
    final ignoredPermissionHandler =
        powerState == IosBluetoothPowerState.poweredOn &&
            rawPermission != SdkPermissionStatus.granted &&
            rawPermission != SdkPermissionStatus.limited;

    debugPrint(
      'IOS_BLE_EFFECTIVE_ACCESS rawPermission=${rawPermission.name} '
      'adapterState=${powerState.name} '
      'effectiveAuthorization=${effectiveAuthorization.name} '
      'effectiveReady=$effectiveReady '
      'ignoredPermissionHandler=$ignoredPermissionHandler source=$source',
    );

    return (effectivePermission, powered, effectiveAuthorization);
  }

  Future<(SdkPermissionStatus, IosNotificationAuthorizationStatus)>
      _getNotificationPermissionState({required String source}) async {
    final permissionHandlerStatus = await ph.Permission.notification.status;
    final localNotificationsStatus =
        await _readLocalNotificationAuthorizationStatus();
    final resolved = _mapIosNotificationAuthorization(
      permissionHandlerStatus,
      localNotificationsStatus: localNotificationsStatus,
    );
    if (Platform.isIOS) {
      final localNotificationsLabel =
          localNotificationsStatus?.name ?? 'unknown';
      debugPrint(
        'IOS_NOTIFICATION_STATUS_SOURCE '
        'permissionHandler=${permissionHandlerStatus.name} '
        'localNotifications=$localNotificationsLabel '
        'resolved=${resolved.name} source=$source',
      );
    }
    return (_mapNotificationPermissionStatus(resolved), resolved);
  }

  Future<IosNotificationAuthorizationStatus?>
      _readLocalNotificationAuthorizationStatus() async {
    if (!Platform.isIOS) {
      return null;
    }
    try {
      final plugin = FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>();
      final permissions = await plugin?.checkPermissions();
      if (permissions == null) {
        return null;
      }
      if (permissions.isProvisionalEnabled) {
        return IosNotificationAuthorizationStatus.provisional;
      }
      if (permissions.isEnabled ||
          permissions.isAlertEnabled ||
          permissions.isBadgeEnabled ||
          permissions.isSoundEnabled) {
        return IosNotificationAuthorizationStatus.authorized;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  IosLocationAuthorizationStatus _mapIosLocationAuthorization(
    LocationPermission permission,
  ) {
    if (!Platform.isIOS) {
      return IosLocationAuthorizationStatus.unableToDetermine;
    }
    return switch (permission) {
      LocationPermission.always => IosLocationAuthorizationStatus.always,
      LocationPermission.whileInUse =>
        IosLocationAuthorizationStatus.whileInUse,
      LocationPermission.denied => IosLocationAuthorizationStatus.denied,
      LocationPermission.deniedForever =>
        IosLocationAuthorizationStatus.deniedForever,
      LocationPermission.unableToDetermine =>
        IosLocationAuthorizationStatus.unableToDetermine,
    };
  }

  IosNotificationAuthorizationStatus _mapIosNotificationAuthorization(
    ph.PermissionStatus status, {
    IosNotificationAuthorizationStatus? localNotificationsStatus,
  }) {
    if (!Platform.isIOS) return IosNotificationAuthorizationStatus.unknown;
    if (localNotificationsStatus ==
            IosNotificationAuthorizationStatus.authorized ||
        localNotificationsStatus ==
            IosNotificationAuthorizationStatus.provisional) {
      return localNotificationsStatus!;
    }
    if (status.isGranted) return IosNotificationAuthorizationStatus.authorized;
    if (status.isProvisional) {
      return IosNotificationAuthorizationStatus.provisional;
    }
    if (status.isPermanentlyDenied || status.isRestricted) {
      return IosNotificationAuthorizationStatus.denied;
    }
    if (status.isDenied) {
      return IosNotificationAuthorizationStatus.notDetermined;
    }
    return IosNotificationAuthorizationStatus.unknown;
  }

  SdkPermissionStatus _mapNotificationPermissionStatus(
    IosNotificationAuthorizationStatus status,
  ) {
    return switch (status) {
      IosNotificationAuthorizationStatus.authorized =>
        SdkPermissionStatus.granted,
      IosNotificationAuthorizationStatus.provisional ||
      IosNotificationAuthorizationStatus.ephemeral =>
        SdkPermissionStatus.limited,
      IosNotificationAuthorizationStatus.denied =>
        SdkPermissionStatus.permanentlyDenied,
      IosNotificationAuthorizationStatus.notDetermined =>
        SdkPermissionStatus.denied,
      IosNotificationAuthorizationStatus.unknown => SdkPermissionStatus.unknown,
    };
  }

  void _logIosState({
    required IosBluetoothAuthorizationStatus bluetoothAuthorization,
    required IosBluetoothPowerState bluetoothPowerState,
    required IosLocationAuthorizationStatus locationAuthorization,
    required bool locationServicesEnabled,
    required IosNotificationAuthorizationStatus notificationAuthorization,
    required String source,
  }) {
    if (!Platform.isIOS) return;
    debugPrint(
      'IOS_PERMISSION_STATE type=bluetooth '
      'authorization=${bluetoothAuthorization.name} '
      'powered=${bluetoothPowerState.name} source=$source',
    );
    debugPrint(
      'IOS_PERMISSION_STATE type=location '
      'permission=${locationAuthorization.name} '
      'servicesEnabled=$locationServicesEnabled source=$source',
    );
    debugPrint(
      'IOS_PERMISSION_STATE type=notifications '
      'authorization=${notificationAuthorization.name} source=$source',
    );
  }

  void _logIosPermissionRequest({
    required String type,
    required String result,
  }) {
    if (!Platform.isIOS) return;
    debugPrint(
      'IOS_PERMISSION_REQUEST type=$type result=$result source=sdk',
    );
  }
}
