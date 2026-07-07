import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  group('DeviceCountryConfigStatus', () {
    test('idle factory starts with the idle outcome', () {
      final status = DeviceCountryConfigStatus.idle();
      expect(status.outcome, DeviceCountryConfigOutcome.idle);
      expect(status.isApplied, isFalse);
      expect(status.countryIso, isNull);
    });

    test('copyWith overrides provided fields and keeps the rest', () {
      final base = DeviceCountryConfigStatus.idle();
      final updated = base.copyWith(
        outcome: DeviceCountryConfigOutcome.applied,
        countryIso: 'ES',
        targetRegion: LoraRegionCode.eu868,
        deviceReportedRegion: LoraRegionCode.eu868,
        deviceConfig: 'EU868',
      );

      expect(updated.outcome, DeviceCountryConfigOutcome.applied);
      expect(updated.isApplied, isTrue);
      expect(updated.countryIso, 'ES');
      expect(updated.targetRegion, LoraRegionCode.eu868);
      expect(updated.deviceConfig, 'EU868');
      expect(updated.updatedAt, base.updatedAt);
    });

    test('copyWith can reset nullable fields back to null', () {
      final status = DeviceCountryConfigStatus.idle().copyWith(
        countryIso: 'ES',
        detail: 'note',
      );
      final cleared = status.copyWith(countryIso: null, detail: null);
      expect(cleared.countryIso, isNull);
      expect(cleared.detail, isNull);
    });
  });
}
