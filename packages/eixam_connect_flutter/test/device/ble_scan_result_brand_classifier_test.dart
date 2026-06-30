import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:eixam_connect_flutter/src/device/ble_scan_result.dart';
import 'package:eixam_connect_flutter/src/device/ble_scan_result_brand_classifier.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyBleDiscoveredDeviceBrand', () {
    test('returns eixam when the advertised service UUID matches', () {
      final result = classifyBleDiscoveredDeviceBrand(
        name: 'Random name',
        advertisedServiceUuids: <String>[EixamBleProtocol.serviceUuid],
      );

      expect(result, BleDiscoveredDeviceBrand.eixam);
    });

    test('returns eixam when the device name contains eixam', () {
      final result = classifyBleDiscoveredDeviceBrand(
        name: 'portable eIxAm node',
        advertisedServiceUuids: const <String>[],
      );

      expect(result, BleDiscoveredDeviceBrand.eixam);
    });

    test('returns meshtastic when the device name contains meshtastic', () {
      final result = classifyBleDiscoveredDeviceBrand(
        name: 'Meshtastic T-Echo',
        advertisedServiceUuids: const <String>[],
      );

      expect(result, BleDiscoveredDeviceBrand.meshtastic);
    });

    test('returns unknown when no rule matches', () {
      final result = classifyBleDiscoveredDeviceBrand(
        name: 'Generic Tracker',
        advertisedServiceUuids: const <String>[],
      );

      expect(result, BleDiscoveredDeviceBrand.unknown);
    });

    test('handles null and empty names safely', () {
      expect(
        classifyBleDiscoveredDeviceBrand(
          name: null,
          advertisedServiceUuids: null,
        ),
        BleDiscoveredDeviceBrand.unknown,
      );
      expect(
        classifyBleDiscoveredDeviceBrand(
          name: '   ',
          advertisedServiceUuids: const <String>[],
        ),
        BleDiscoveredDeviceBrand.unknown,
      );
    });
  });

  test('BleScanResult exposes brand classification with a safe default', () {
    final scanResult = BleScanResult(
      deviceId: 'device-1',
      name: 'Unknown',
      rssi: -70,
      connectable: true,
      discoveredAt: DateTime.utc(2026, 4, 24),
    );

    expect(scanResult.brandClassification, BleDiscoveredDeviceBrand.unknown);
  });
}
