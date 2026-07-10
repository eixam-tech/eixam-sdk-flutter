import 'package:eixam_connect_core/eixam_connect_core.dart'
    show EixamBleScanResult;

import '../public/enums/discovered_device_brand.dart';
import 'eixam_ble_protocol.dart';

/// Lightweight scan result returned by a BLE client implementation.
class BleScanResult {
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
  final String deviceId;
  final String? canonicalHardwareId;
  final String name;
  final int rssi;
  final bool connectable;
  final List<String> advertisedServiceUuids;
  final BleDiscoveredDeviceBrand brandClassification;
  final DateTime discoveredAt;

  EixamBleScanResult toPublic() {
    return EixamBleScanResult(
      deviceId: deviceId,
      canonicalHardwareId: canonicalHardwareId,
      name: name,
      rssi: rssi,
      connectable: connectable,
      brandClassification: brandClassification,
      isEixamDevice: _isEixamDevice,
      discoveredAt: discoveredAt,
    );
  }

  bool get _isEixamDevice {
    final eixamServiceUuid = EixamBleProtocol.serviceUuid.toLowerCase();
    final hasEixamService = advertisedServiceUuids.any(
      (uuid) => uuid.trim().toLowerCase() == eixamServiceUuid,
    );
    return hasEixamService ||
        brandClassification == BleDiscoveredDeviceBrand.eixam ||
        name.trim().toLowerCase().contains('eixam');
  }
}
