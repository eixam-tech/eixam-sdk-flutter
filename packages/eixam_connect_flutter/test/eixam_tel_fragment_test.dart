import 'package:eixam_connect_flutter/src/device/eixam_tel_fragment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EixamTelFragment.tryParse', () {
    test('parses a valid aggregate fragment', () {
      final fragment = EixamTelFragment.tryParse(<int>[
        0xD0,
        0x06,
        0x00,
        0x00,
        0x00,
        0xAA,
        0xBB,
        0xCC,
      ]);

      expect(fragment, isNotNull);
      expect(fragment!.totalLength, 6);
      expect(fragment.offset, 0);
      expect(fragment.fragmentPayload, <int>[0xAA, 0xBB, 0xCC]);
      expect(fragment.fragmentLength, 3);
    });

    test('rejects invalid aggregate fragments', () {
      expect(
        EixamTelFragment.tryParse(<int>[0xD0, 0x00, 0x00, 0x00, 0x00, 0xAA]),
        isNull,
      );
      expect(
        EixamTelFragment.tryParse(<int>[0x01, 0x06, 0x00, 0x00, 0x00, 0xAA]),
        isNull,
      );
      expect(
        EixamTelFragment.tryParse(<int>[0xD0, 0x06, 0x00, 0x00, 0x00]),
        isNull,
      );
    });
  });
}
