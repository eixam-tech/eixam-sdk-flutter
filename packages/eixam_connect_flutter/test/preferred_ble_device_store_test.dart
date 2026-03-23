import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/device/preferred_ble_device.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('PreferredBleDeviceStore', () {
    test('saves and loads the preferred device', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = PreferredBleDeviceStore(
        localStore: SharedPrefsSdkStore(),
      );
      final expected = PreferredBleDevice(
        deviceId: 'ble-demo-r1',
        displayName: 'EIXAM Demo',
        lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
      );

      await store.savePreferredDevice(expected);

      final actual = await store.getPreferredDevice();
      expect(actual, isNotNull);
      expect(actual!.deviceId, expected.deviceId);
      expect(actual.displayName, expected.displayName);
      expect(actual.lastConnectedAt, expected.lastConnectedAt);
    });

    test('persists the manual disconnect flag', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = PreferredBleDeviceStore(
        localStore: SharedPrefsSdkStore(),
      );

      await store.saveManualDisconnectRequested(true);
      expect(await store.readManualDisconnectRequested(), isTrue);

      await store.saveManualDisconnectRequested(false);
      expect(await store.readManualDisconnectRequested(), isFalse);
    });
  });
}
