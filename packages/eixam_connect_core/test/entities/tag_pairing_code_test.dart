import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  test('normalizes documented label shapes without changing the prefix', () {
    for (final raw in [' n693756e\n', 'a6d447db']) {
      final result = TagPairingCode.inspect(raw);
      expect(result.format, TagPairingCodeFormat.structurallyValid);
      expect(result.code!.normalized, raw.trim().toUpperCase());
    }
    final code = TagPairingCode.inspect('N693756E').code!;
    expect(code.hardwareSuffix, '93756E');
    expect(code.legacyAdvertisingSuffix, '756E');
  });

  test('malformed known formats are invalid, other QR formats unsupported', () {
    for (final raw in [
      '',
      'N693756',
      'N693756EE',
      'N69375GE',
      'N693 56E',
      'N693756E\u0000',
    ]) {
      expect(TagPairingCode.inspect(raw).format, TagPairingCodeFormat.invalid);
    }
    for (final raw in [
      'ABCDEFGH',
      'Z693756E',
      'https://example.com/N693756E',
      'eixam://person/12345678',
    ]) {
      final result = TagPairingCode.inspect(raw);
      expect(result.format, TagPairingCodeFormat.unsupported);
      expect(result.code, isNull);
    }
  });
}
