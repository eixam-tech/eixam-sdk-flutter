import '../entities/device_status.dart';

/// Stable per-TAG key shared by TAG alert settings and device-scoped config:
/// canonical hardware id, else `node:<id>`, else the transport device id.
String tagAlertDeviceKey(DeviceStatus status) {
  final hardware = status.canonicalHardwareId?.trim();
  if (hardware != null && hardware.isNotEmpty) {
    return hardware;
  }
  final node = status.nodeId;
  if (node != null) {
    return 'node:$node';
  }
  return status.deviceId;
}
