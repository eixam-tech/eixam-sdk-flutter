import 'package:eixam_connect_flutter/src/device/real_ble_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Android persisted-device status never requests system enumeration',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final platform = _DeniedEnumerationPlatform();
      FlutterBluePlusPlatform.instance = platform;
      final client = RealBleClient(
        isSupportedProvider: () async => true,
        adapterStateProvider: () => BluetoothAdapterState.on,
        adapterStateStreamProvider: () => const Stream.empty(),
      );
      await client.initialize();
      expect(await client.isConnected('CF:82:59:4B:1A:A8'), isFalse);
      expect(platform.enumerations, isEmpty);
      // Re-entry uses the same exact identity and remains a passive status read.
      expect(await client.isConnected('CF:82:59:4B:1A:A8'), isFalse);
      expect(platform.enumerations, isEmpty);
      platform.denied = false;
      expect(await client.hasSystemAssociation('CF:82:59:4B:1A:A8'), isFalse);
      expect(platform.enumerations, ['bonded']);
    },
  );
}

final class _DeniedEnumerationPlatform extends FlutterBluePlusPlatform {
  final enumerations = <String>[];
  bool denied = true;

  @override
  Future<BmDevicesList> getSystemDevices(BmSystemDevicesRequest request) async {
    enumerations.add('system');
    throw StateError('Nearby Devices denied');
  }

  @override
  Future<BmDevicesList> getBondedDevices(BmBondedDevicesRequest request) async {
    enumerations.add('bonded');
    if (denied) throw StateError('Nearby Devices denied');
    return BmDevicesList(devices: const []);
  }
}
