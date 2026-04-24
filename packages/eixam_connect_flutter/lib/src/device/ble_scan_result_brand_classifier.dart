import '../public/enums/discovered_device_brand.dart';
import 'eixam_ble_protocol.dart';

BleDiscoveredDeviceBrand classifyBleDiscoveredDeviceBrand({
  required String? name,
  required List<String>? advertisedServiceUuids,
}) {
  if (_containsEixamServiceUuid(advertisedServiceUuids)) {
    return BleDiscoveredDeviceBrand.eixam;
  }

  final normalizedName = (name ?? '').trim().toLowerCase();
  if (normalizedName.contains('eixam')) {
    return BleDiscoveredDeviceBrand.eixam;
  }
  if (normalizedName.contains('meshtastic')) {
    return BleDiscoveredDeviceBrand.meshtastic;
  }
  return BleDiscoveredDeviceBrand.unknown;
}

bool _containsEixamServiceUuid(List<String>? advertisedServiceUuids) {
  if (advertisedServiceUuids == null || advertisedServiceUuids.isEmpty) {
    return false;
  }

  final normalizedEixamServiceUuid = EixamBleProtocol.serviceUuid.toLowerCase();
  for (final uuid in advertisedServiceUuids) {
    if (uuid.trim().toLowerCase() == normalizedEixamServiceUuid) {
      return true;
    }
  }
  return false;
}
