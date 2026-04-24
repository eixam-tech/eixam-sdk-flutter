import '../public/enums/discovered_device_brand.dart';

/// Lightweight scan result returned by a BLE client implementation.
class BleScanResult {
  final String deviceId;
  final String? canonicalHardwareId;
  final String name;
  final int rssi;
  final bool connectable;
  final List<String> advertisedServiceUuids;
  final BleDiscoveredDeviceBrand brandClassification;
  final DateTime discoveredAt;

  const BleScanResult({
    required this.deviceId,
    this.canonicalHardwareId,
    required this.name,
    required this.rssi,
    required this.connectable,
    this.advertisedServiceUuids = const <String>[],
    this.brandClassification = BleDiscoveredDeviceBrand.unknown,
    required this.discoveredAt,
  });
}
