import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/device_config_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('DeviceConfigStore', () {
    test('saves and loads a verified applied record for a device', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = DeviceConfigStore(localStore: SharedPrefsSdkStore());
      final at = DateTime.parse('2026-06-30T10:00:00Z');

      await store.saveApplied(
        deviceKey: 'hw-1',
        countryIso: 'ES',
        regionWire: 3, // EU868
        deviceConfig: 'EU868',
        at: at,
      );

      final record = await store.getRecord('hw-1');
      expect(record, isNotNull);
      expect(record!.countryIso, 'ES');
      expect(record.regionWire, LoraRegionCode.eu868.wireValue);
      expect(record.region, LoraRegionCode.eu868);
      expect(record.deviceConfig, 'EU868');
      expect(record.applied, isTrue);
      expect(record.at, at);
    });

    test('records an unsupported attempt with applied = false', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = DeviceConfigStore(localStore: SharedPrefsSdkStore());

      await store.saveUnsupportedAttempt(
        deviceKey: 'hw-1',
        countryIso: 'US',
        regionWire: 1, // US915
      );

      final record = await store.getRecord('hw-1');
      expect(record!.applied, isFalse);
      expect(record.region, LoraRegionCode.us915);
    });

    test('returns null for an unknown device', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = DeviceConfigStore(localStore: SharedPrefsSdkStore());

      expect(await store.getRecord('missing'), isNull);
    });

    test('keeps records isolated per device', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = DeviceConfigStore(localStore: SharedPrefsSdkStore());

      await store.saveApplied(
        deviceKey: 'hw-1',
        countryIso: 'ES',
        regionWire: 3, // EU868
      );
      await store.saveApplied(
        deviceKey: 'hw-2',
        countryIso: 'US',
        regionWire: 1, // US915
      );

      expect((await store.getRecord('hw-1'))!.region, LoraRegionCode.eu868);
      expect((await store.getRecord('hw-2'))!.region, LoraRegionCode.us915);
    });

    test('clear removes only the targeted device record', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = DeviceConfigStore(localStore: SharedPrefsSdkStore());

      await store.saveApplied(
        deviceKey: 'hw-1',
        countryIso: 'ES',
        regionWire: 3, // EU868
      );
      await store.saveApplied(
        deviceKey: 'hw-2',
        countryIso: 'US',
        regionWire: 1, // US915
      );

      await store.clear('hw-1');

      expect(await store.getRecord('hw-1'), isNull);
      expect((await store.getRecord('hw-2'))!.region, LoraRegionCode.us915);
    });
  });
}
