import '../enums/ble_discovered_device_brand.dart';

/// Public BLE discovery result exposed to host apps.
///
/// Protocol/service UUID matching stays inside the SDK. Host apps should use
/// [isEixamDevice] and [brandClassification] instead of inspecting BLE
/// advertisement internals.
class EixamBleScanResult {
  const EixamBleScanResult({
    required this.deviceId,
    this.canonicalHardwareId,
    required this.name,
    required this.rssi,
    required this.connectable,
    required this.brandClassification,
    required this.isEixamDevice,
    required this.discoveredAt,
  });

  final String deviceId;
  final String? canonicalHardwareId;
  final String name;
  final int rssi;
  final bool connectable;
  final BleDiscoveredDeviceBrand brandClassification;
  final bool isEixamDevice;
  final DateTime discoveredAt;
}
