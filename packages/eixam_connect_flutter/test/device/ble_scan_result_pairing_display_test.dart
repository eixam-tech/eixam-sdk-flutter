import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:eixam_connect_flutter/src/device/ble_scan_result.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/meshtastic_ble_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

EixamPairingDisplayCategory? _category({
  required String name,
  List<String> uuids = const <String>[],
}) => BleScanResult(
  deviceId: 'device-1',
  name: name,
  rssi: -60,
  connectable: true,
  advertisedServiceUuids: uuids,
  discoveredAt: DateTime.utc(2026, 1, 1),
).toPublic().pairingDisplayCategory;

void main() {
  test('core pairing-display UUIDs match the BLE protocol constants', () {
    expect(eixamPairingDisplayEixamServiceUuid, EixamBleProtocol.serviceUuid);
    expect(
      eixamPairingDisplayStockServiceUuid,
      MeshtasticBleProtocol.serviceUuid,
    );
  });

  test('toPublic classifies the fresh advertisement for display', () {
    expect(
      _category(name: 'Unknown', uuids: [EixamBleProtocol.serviceUuid]),
      EixamPairingDisplayCategory.eixam,
    );
    expect(
      _category(
        name: 'Meshtastic_a148',
        uuids: [MeshtasticBleProtocol.serviceUuid],
      ),
      EixamPairingDisplayCategory.legacyOrStock,
    );
    expect(
      _category(
        name: 'AdaDFU',
        uuids: ['00001530-1212-efde-1523-785feabcd123'],
      ),
      EixamPairingDisplayCategory.dfuRecovery,
    );
    expect(
      _category(name: 'DfuTarg', uuids: ['fe59']),
      EixamPairingDisplayCategory.dfuRecovery,
    );
    expect(
      _category(
        name: 'EIXAM_GW_0011AABB',
        uuids: [MeshtasticBleProtocol.serviceUuid],
      ),
      EixamPairingDisplayCategory.hidden,
    );
    expect(_category(name: 'Galaxy Buds'), EixamPairingDisplayCategory.hidden);
  });

  test('classification does not change existing brand or DFU flags', () {
    final public = BleScanResult(
      deviceId: 'device-1',
      name: 'EIXAM_GW_0011AABB',
      rssi: -60,
      connectable: true,
      brandClassification: BleDiscoveredDeviceBrand.eixam,
      discoveredAt: DateTime.utc(2026, 1, 1),
    ).toPublic();
    expect(public.brandClassification, BleDiscoveredDeviceBrand.eixam);
    expect(public.isDfuBootloader, isFalse);
    expect(public.pairingDisplayCategory, EixamPairingDisplayCategory.hidden);
  });

  test('host-built scan results are unclassified by default', () {
    final result = EixamBleScanResult(
      deviceId: 'd',
      name: 'n',
      rssi: 0,
      connectable: true,
      brandClassification: BleDiscoveredDeviceBrand.unknown,
      isEixamDevice: false,
      discoveredAt: DateTime.utc(2026, 1, 1),
    );
    expect(result.pairingDisplayCategory, isNull);
  });
}
