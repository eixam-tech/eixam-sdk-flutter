/// Lightweight scan result returned by a BLE client implementation.
class BleScanResult {
  final String deviceId;
  final String name;
  final int rssi;
  final bool connectable;
  final DateTime discoveredAt;

  const BleScanResult({
    required this.deviceId,
    required this.name,
    required this.rssi,
    required this.connectable,
    required this.discoveredAt,
  });
}
