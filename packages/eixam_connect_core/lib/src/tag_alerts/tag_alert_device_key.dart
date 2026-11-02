import '../entities/device_status.dart';

/// Stable per-TAG key for TAG alert settings, battery cycles and notification
/// slots: the canonical hardware id when there is one (the BLE MAC on Android),
/// otherwise the transport device id (the CoreBluetooth UUID on iOS, stable
/// for that phone).
///
/// The firmware node id is deliberately **not** part of the key. It arrives
/// late (after the first `0x23` reply, which can miss the pair-time timeout),
/// so a key that used it would change under the same physical TAG and strand
/// the TAG's settings. Device migration re-keys explicitly.
String tagAlertKeyFor({
  String? canonicalHardwareId,
  required String deviceId,
}) {
  final hardware = canonicalHardwareId?.trim();
  if (hardware != null && hardware.isNotEmpty) {
    return hardware;
  }
  return deviceId;
}

String tagAlertDeviceKey(DeviceStatus status) => tagAlertKeyFor(
  canonicalHardwareId: status.canonicalHardwareId,
  deviceId: status.deviceId,
);
