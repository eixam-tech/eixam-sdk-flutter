import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:eixam_connect_flutter/src/device/ble_scan_result.dart';
import 'package:eixam_connect_flutter/src/device/ble_scan_result_brand_classifier.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/meshtastic_ble_protocol.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyBleDiscoveredDeviceBrand', () {
    for (final name in <String?>['756E_756e', '', null]) {
      for (final uuid in <String>[
        MeshtasticBleProtocol.serviceUuid,
        MeshtasticBleProtocol.serviceUuid.toUpperCase(),
        ' ${MeshtasticBleProtocol.serviceUuid} ',
        Guid(MeshtasticBleProtocol.serviceUuid).str,
      ]) {
        test('Meshtastic service recognizes name=$name uuid=$uuid', () {
          expect(
            classifyBleDiscoveredDeviceBrand(
              name: name,
              advertisedServiceUuids: [uuid],
            ),
            BleDiscoveredDeviceBrand.meshtastic,
          );
        });
      }
    }

    test('unrelated standard service does not identify Meshtastic', () {
      expect(
        classifyBleDiscoveredDeviceBrand(
          name: '756E_756e',
          advertisedServiceUuids: [
            '180f',
            '0000180f-0000-1000-8000-00805f9b34fb',
          ],
        ),
        BleDiscoveredDeviceBrand.unknown,
      );
    });

    test('Eixam service and existing name take precedence over Meshtastic', () {
      for (final name in ['756E_756e', 'EIXAM_TAG']) {
        expect(
          classifyBleDiscoveredDeviceBrand(
            name: name,
            advertisedServiceUuids: [
              MeshtasticBleProtocol.serviceUuid,
              if (name == '756E_756e')
                EixamBleProtocol.serviceUuid.toUpperCase(),
            ],
          ),
          BleDiscoveredDeviceBrand.eixam,
        );
      }
    });

    test('DFU recovery flag survives short and expanded platform UUIDs', () {
      for (final dfuUuid in [
        'fe59',
        'FE59',
        '0000fe59-0000-1000-8000-00805f9b34fb',
        '00001530-1212-efde-1523-785feabcd123',
        '00001530-1212-EFDE-1523-785FEABCD123',
      ]) {
        for (final services in <List<String>>[
          [dfuUuid],
          [dfuUuid, MeshtasticBleProtocol.serviceUuid],
          [dfuUuid, EixamBleProtocol.serviceUuid],
        ]) {
          final brand = classifyBleDiscoveredDeviceBrand(
            name: 'Unrelated friendly name',
            advertisedServiceUuids: services,
          );
          final result = BleScanResult(
            deviceId: 'recovery',
            name: 'DfuTarg',
            rssi: -60,
            connectable: true,
            advertisedServiceUuids: services,
            brandClassification: brand,
            discoveredAt: DateTime.utc(2026),
          ).toPublic();
          expect(result.isDfuBootloader, isTrue);
          expect(
            brand,
            services.contains(EixamBleProtocol.serviceUuid)
                ? BleDiscoveredDeviceBrand.eixam
                : services.contains(MeshtasticBleProtocol.serviceUuid)
                ? BleDiscoveredDeviceBrand.meshtastic
                : BleDiscoveredDeviceBrand.unknown,
          );
        }
      }
    });

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
