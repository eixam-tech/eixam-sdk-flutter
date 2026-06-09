import '../enums/sdk_permission_status.dart';

enum IosBluetoothAuthorizationStatus {
  notDetermined,
  allowed,
  denied,
  restricted,
  unknown,
}

enum IosBluetoothPowerState {
  poweredOn,
  poweredOff,
  unauthorized,
  unsupported,
  unknown,
}

enum IosLocationAuthorizationStatus {
  denied,
  deniedForever,
  whileInUse,
  always,
  unableToDetermine,
}

enum IosNotificationAuthorizationStatus {
  notDetermined,
  denied,
  authorized,
  provisional,
  ephemeral,
  unknown,
}

/// Aggregated runtime permission snapshot exposed by the SDK.
///
/// The host app can use this object to paint UI, decide whether Bluetooth
/// pairing can start and determine if location / notifications are available.
class PermissionState {
  const PermissionState({
    this.location = SdkPermissionStatus.unknown,
    this.backgroundLocation = SdkPermissionStatus.unknown,
    this.notifications = SdkPermissionStatus.unknown,
    this.bluetooth = SdkPermissionStatus.unknown,
    this.bluetoothEnabled = false,
    this.iosBluetoothAuthorization = IosBluetoothAuthorizationStatus.unknown,
    this.iosBluetoothPowerState = IosBluetoothPowerState.unknown,
    this.iosLocationAuthorization =
        IosLocationAuthorizationStatus.unableToDetermine,
    this.locationServicesEnabled = false,
    this.iosNotificationAuthorization =
        IosNotificationAuthorizationStatus.unknown,
  });

  final SdkPermissionStatus location;
  final SdkPermissionStatus backgroundLocation;
  final SdkPermissionStatus notifications;
  final SdkPermissionStatus bluetooth;
  final bool bluetoothEnabled;
  final IosBluetoothAuthorizationStatus iosBluetoothAuthorization;
  final IosBluetoothPowerState iosBluetoothPowerState;
  final IosLocationAuthorizationStatus iosLocationAuthorization;
  final bool locationServicesEnabled;
  final IosNotificationAuthorizationStatus iosNotificationAuthorization;

  bool get hasLocationAccess =>
      location == SdkPermissionStatus.granted ||
      location == SdkPermissionStatus.limited;

  bool get hasNotificationAccess =>
      notifications == SdkPermissionStatus.granted ||
      notifications == SdkPermissionStatus.limited;

  bool get hasBluetoothAccess =>
      bluetooth == SdkPermissionStatus.granted ||
      bluetooth == SdkPermissionStatus.limited;

  bool get hasEffectiveBluetoothAccess =>
      hasBluetoothAccess ||
      iosBluetoothPowerState == IosBluetoothPowerState.poweredOn;

  bool get canUseBluetooth => hasEffectiveBluetoothAccess && bluetoothEnabled;

  bool get hasBackgroundLocationAccess =>
      backgroundLocation == SdkPermissionStatus.granted ||
      backgroundLocation == SdkPermissionStatus.limited;

  bool get bluetoothReady => canUseBluetooth;

  bool get foregroundLocationReady =>
      hasLocationAccess && locationServicesEnabled;

  bool get backgroundLocationReady =>
      hasBackgroundLocationAccess && locationServicesEnabled;

  bool get notificationReady => hasNotificationAccess;

  bool get foregroundPairingReady => bluetoothReady;

  bool get canPairDevice => foregroundPairingReady;

  bool get backgroundProtectionReady =>
      bluetoothReady && foregroundLocationReady && backgroundLocationReady;

  bool get canRunProtectionInBackground => backgroundProtectionReady;

  PermissionState copyWith({
    SdkPermissionStatus? location,
    SdkPermissionStatus? backgroundLocation,
    SdkPermissionStatus? notifications,
    SdkPermissionStatus? bluetooth,
    bool? bluetoothEnabled,
    IosBluetoothAuthorizationStatus? iosBluetoothAuthorization,
    IosBluetoothPowerState? iosBluetoothPowerState,
    IosLocationAuthorizationStatus? iosLocationAuthorization,
    bool? locationServicesEnabled,
    IosNotificationAuthorizationStatus? iosNotificationAuthorization,
  }) {
    return PermissionState(
      location: location ?? this.location,
      backgroundLocation: backgroundLocation ?? this.backgroundLocation,
      notifications: notifications ?? this.notifications,
      bluetooth: bluetooth ?? this.bluetooth,
      bluetoothEnabled: bluetoothEnabled ?? this.bluetoothEnabled,
      iosBluetoothAuthorization:
          iosBluetoothAuthorization ?? this.iosBluetoothAuthorization,
      iosBluetoothPowerState:
          iosBluetoothPowerState ?? this.iosBluetoothPowerState,
      iosLocationAuthorization:
          iosLocationAuthorization ?? this.iosLocationAuthorization,
      locationServicesEnabled:
          locationServicesEnabled ?? this.locationServicesEnabled,
      iosNotificationAuthorization:
          iosNotificationAuthorization ?? this.iosNotificationAuthorization,
    );
  }
}
