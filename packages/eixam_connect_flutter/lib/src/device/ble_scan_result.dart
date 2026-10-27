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
    this.advertisedLocalName,
    required this.rssi,
    required this.connectable,
    this.advertisedServiceUuids = const <String>[],
    this.brandClassification = BleDiscoveredDeviceBrand.unknown,
    required this.discoveredAt,
  });
  final String deviceId;
  final String? canonicalHardwareId;
  final String name;
  final String? advertisedLocalName;
  final int rssi;
  final bool connectable;
  final List<String> advertisedServiceUuids;
  final BleDiscoveredDeviceBrand brandClassification;
  final DateTime discoveredAt;

  EixamBleScanResult toPublic() {
    return EixamBleScanResult(
      deviceId: deviceId,
      canonicalHardwareId: canonicalHardwareId,
      advertisedEixamIdentity: _advertisedEixamIdentity,
      name: name,
      rssi: rssi,
      connectable: connectable,
      brandClassification: brandClassification,
      isEixamDevice: _isEixamDevice,
      discoveredAt: discoveredAt,
      isDfuBootloader: _isDfuBootloader,
    );
  }

  String? get _advertisedEixamIdentity {
    final localName = advertisedLocalName?.toUpperCase();
    if (brandClassification != BleDiscoveredDeviceBrand.eixam ||
        !_hasEixamService ||
        localName == null ||
        !RegExp(r'^EIXAM_A6[0-9A-F]{6}$').hasMatch(localName)) {
      return null;
    }
    return localName;
  }

  bool get _hasEixamService => advertisedServiceUuids.any(
    (uuid) => uuid.trim().toLowerCase() == EixamBleProtocol.serviceUuid,
  );

  // Nordic Secure DFU and the legacy Nordic/Adafruit DFU service identify
  // recovery mode independently of a peripheral's friendly name.
  bool get _isDfuBootloader {
    return advertisedServiceUuids.any((uuid) {
      final normalized = uuid.trim().toLowerCase();
      return normalized == 'fe59' ||
          normalized == '0000fe59-0000-1000-8000-00805f9b34fb' ||
          normalized == '00001530-1212-efde-1523-785feabcd123';
    });
  }

  bool get _isEixamDevice {
    return _hasEixamService ||
        brandClassification == BleDiscoveredDeviceBrand.eixam ||
        name.trim().toLowerCase().contains('eixam');
  }
}
