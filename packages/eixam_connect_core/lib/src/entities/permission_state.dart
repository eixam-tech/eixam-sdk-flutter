import '../enums/sdk_permission_status.dart';

/// Aggregated runtime permission snapshot exposed by the SDK.
///
/// The host app can use this object to paint UI, decide whether Bluetooth
/// pairing can start and determine if location / notifications are available.
class PermissionState {
  final SdkPermissionStatus location;
  final SdkPermissionStatus notifications;
  final SdkPermissionStatus bluetooth;
  final bool bluetoothEnabled;

  const PermissionState({
    this.location = SdkPermissionStatus.unknown,
    this.notifications = SdkPermissionStatus.unknown,
    this.bluetooth = SdkPermissionStatus.unknown,
    this.bluetoothEnabled = false,
  });

  bool get hasLocationAccess =>
      location == SdkPermissionStatus.granted ||
      location == SdkPermissionStatus.limited;

  bool get hasNotificationAccess =>
      notifications == SdkPermissionStatus.granted ||
      notifications == SdkPermissionStatus.limited;

  bool get hasBluetoothAccess =>
      bluetooth == SdkPermissionStatus.granted ||
      bluetooth == SdkPermissionStatus.limited;

  bool get canUseBluetooth => hasBluetoothAccess && bluetoothEnabled;

  PermissionState copyWith({
    SdkPermissionStatus? location,
    SdkPermissionStatus? notifications,
    SdkPermissionStatus? bluetooth,
    bool? bluetoothEnabled,
  }) {
    return PermissionState(
      location: location ?? this.location,
      notifications: notifications ?? this.notifications,
      bluetooth: bluetooth ?? this.bluetooth,
      bluetoothEnabled: bluetoothEnabled ?? this.bluetoothEnabled,
    );
  }
}
