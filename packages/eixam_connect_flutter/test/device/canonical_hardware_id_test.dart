import 'package:eixam_connect_flutter/src/device/canonical_hardware_id.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeCanonicalHardwareId', () {
    test('normalizes a lowercase BLE MAC to canonical uppercase form', () {
      expect(
        normalizeCanonicalHardwareId('  cf:82:00:00:00:01  '),
        'CF:82:00:00:00:01',
      );
    });

    test('does not confuse node ids or platform UUIDs with hardware ids', () {
      expect(normalizeCanonicalHardwareId('4660'), isNull);
      expect(
        normalizeCanonicalHardwareId(
          '550e8400-e29b-41d4-a716-446655440000',
        ),
        isNull,
      );
    });
  });
}
