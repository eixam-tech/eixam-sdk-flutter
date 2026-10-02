import '../public/enums/discovered_device_brand.dart';
import 'eixam_ble_protocol.dart';
import 'meshtastic_ble_protocol.dart';

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
  // Discovery identifies a candidate only. The metadata probe still verifies
  // hardware compatibility before migration; DFU remains a separate scan flag.
  if (advertisedServiceUuids?.any(
        (uuid) =>
            uuid.trim().toLowerCase() == MeshtasticBleProtocol.serviceUuid,
      ) ==
      true) {
    return BleDiscoveredDeviceBrand.meshtastic;
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
