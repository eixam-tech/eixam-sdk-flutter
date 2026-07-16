import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  group('DeviceCountryConfig', () {
    test('reads the backend region byte verbatim (source of truth)', () {
      // Real GET /v1/sdk/device-configs shape: raw config JSON with the byte.
      final config = DeviceCountryConfig.fromJson(<String, dynamic>{
        'region': 'AS923',
        'lora_region_code': 12,
        'sos': <String, dynamic>{'freq_mhz': 922.2},
      });

      expect(config.deviceConfig, 'AS923');
      expect(config.loraRegionByte, 12);
      expect(config.regionByte, 12);
      expect(config.regionCode, LoraRegionCode.as923);
      expect(config.hasApplicableRegion, isTrue);
    });

    test('applies each staging region byte from the DB (no in-SDK mapping)',
        () {
      const expected = <int, LoraRegionCode>{
        1: LoraRegionCode.us915,
        2: LoraRegionCode.eu433,
        3: LoraRegionCode.eu868,
        4: LoraRegionCode.cn470,
        5: LoraRegionCode.as923jp,
        6: LoraRegionCode.au915,
        7: LoraRegionCode.kr920,
        8: LoraRegionCode.tw,
        9: LoraRegionCode.ru864,
        10: LoraRegionCode.in865,
        11: LoraRegionCode.nz865,
        12: LoraRegionCode.as923,
        15: LoraRegionCode.ua868,
        17: LoraRegionCode.my919,
        18: LoraRegionCode.sg923,
        21: LoraRegionCode.ph915,
        24: LoraRegionCode.kz863,
        25: LoraRegionCode.np865,
        26: LoraRegionCode.br902,
      };
      expected.forEach((byte, code) {
        final config = DeviceCountryConfig.fromJson(
          <String, dynamic>{'lora_region_code': byte},
        );
        expect(config.regionByte, byte, reason: '$byte');
        expect(config.regionCode, code, reason: '$byte');
      });
    });

    test('falls back to EU868 when the backend omits the region byte', () {
      // Unmapped country / missing byte -> EU fallback (never left region-less).
      final missing = DeviceCountryConfig.fromJson(<String, dynamic>{
        'region': 'EU868',
      });
      expect(missing.loraRegionByte, isNull);
      expect(missing.regionByte, LoraRegionCode.eu868.wireValue);
      expect(missing.regionCode, LoraRegionCode.eu868);
      expect(missing.hasApplicableRegion, isTrue);

      final empty = DeviceCountryConfig.fromJson(<String, dynamic>{});
      expect(empty.regionByte, LoraRegionCode.eu868.wireValue);
      expect(empty.hasApplicableRegion, isTrue);

      // A zero/invalid byte also falls back to EU rather than writing UNSET.
      final zero = DeviceCountryConfig.fromJson(
        <String, dynamic>{'lora_region_code': 0},
      );
      expect(zero.regionByte, LoraRegionCode.eu868.wireValue);
    });

    test('preserves unknown fields in the raw passthrough', () {
      final config = DeviceCountryConfig.fromJson(<String, dynamic>{
        'region': 'AS923',
        'lora_region_code': 12,
        'duty_cycle': 1.0,
        'frequencies': <double>[923.2, 923.4],
      });

      expect(config.raw['duty_cycle'], 1.0);
      expect(config.raw['frequencies'], <double>[923.2, 923.4]);
    });
  });
}
