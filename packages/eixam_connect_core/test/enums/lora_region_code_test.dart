import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  group('LoraRegionCode', () {
    test('wire values mirror the firmware Meshtastic RegionCode enum', () {
      expect(LoraRegionCode.unset.wireValue, 0);
      expect(LoraRegionCode.us915.wireValue, 1);
      expect(LoraRegionCode.eu433.wireValue, 2);
      expect(LoraRegionCode.eu868.wireValue, 3);
      expect(LoraRegionCode.cn470.wireValue, 4); // RegionCode_CN
      expect(LoraRegionCode.as923jp.wireValue, 5); // RegionCode_JP
      expect(LoraRegionCode.au915.wireValue, 6); // RegionCode_ANZ
      expect(LoraRegionCode.kr920.wireValue, 7); // RegionCode_KR
      expect(LoraRegionCode.tw.wireValue, 8); // RegionCode_TW
      expect(LoraRegionCode.ru864.wireValue, 9); // RegionCode_RU
      expect(LoraRegionCode.in865.wireValue, 10); // RegionCode_IN
      expect(LoraRegionCode.nz865.wireValue, 11); // RegionCode_NZ_865
      expect(LoraRegionCode.as923.wireValue, 12); // RegionCode_TH (AS923-1)
      expect(LoraRegionCode.ua868.wireValue, 15); // RegionCode_UA_868
      expect(LoraRegionCode.my919.wireValue, 17); // RegionCode_MY_919
      expect(LoraRegionCode.sg923.wireValue, 18); // RegionCode_SG_923
      expect(LoraRegionCode.ph915.wireValue, 21); // RegionCode_PH_915
      expect(LoraRegionCode.kz863.wireValue, 24); // RegionCode_KZ_863
      expect(LoraRegionCode.np865.wireValue, 25); // RegionCode_NP_865
      expect(LoraRegionCode.br902.wireValue, 26); // RegionCode_BR_902
    });

    test('wire values are unique across all regions (no duplicate byte)', () {
      final values = LoraRegionCode.values.map((r) => r.wireValue).toList();
      expect(values.toSet().length, values.length,
          reason: 'two regions share a wire byte');
    });

    test('fromWireValue round-trips every region', () {
      for (final region in LoraRegionCode.values) {
        expect(LoraRegionCode.fromWireValue(region.wireValue), region,
            reason: '${region.name} (byte ${region.wireValue})');
      }
    });

    test('fromWireValue labels a region byte and defaults to unset', () {
      expect(LoraRegionCode.fromWireValue(3), LoraRegionCode.eu868);
      expect(LoraRegionCode.fromWireValue(1), LoraRegionCode.us915);
      expect(LoraRegionCode.fromWireValue(12), LoraRegionCode.as923);
      expect(LoraRegionCode.fromWireValue(9), LoraRegionCode.ru864);
      // Every region present in the DB must have a label (not unset).
      expect(LoraRegionCode.fromWireValue(8), LoraRegionCode.tw);
      expect(LoraRegionCode.fromWireValue(18), LoraRegionCode.sg923);
      expect(LoraRegionCode.fromWireValue(26), LoraRegionCode.br902);
      // 13 (LORA_24) / 99 are not regions we carry a config for -> unset.
      expect(LoraRegionCode.fromWireValue(13), LoraRegionCode.unset);
      expect(LoraRegionCode.fromWireValue(99), LoraRegionCode.unset);
    });

    test('isApplicable is false only for unset', () {
      expect(LoraRegionCode.unset.isApplicable, isFalse);
      expect(LoraRegionCode.eu868.isApplicable, isTrue);
      expect(LoraRegionCode.us915.isApplicable, isTrue);
    });
  });
}
