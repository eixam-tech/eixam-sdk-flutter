import 'package:eixam_connect_flutter/src/device/eixam_tel_fragment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EixamTelFragment.tryParse', () {
    test('parses a valid D0 fragment', () {
      final fragment = EixamTelFragment.tryParse(<int>[
        0xD0,
        0x08,
        0x00,
        0x00,
        0x00,
        0xAA,
        0xBB,
        0xCC,
      ]);

      expect(fragment, isNotNull);
      expect(fragment!.totalLength, 8);
      expect(fragment.offset, 0);
      expect(fragment.fragmentPayload, <int>[0xAA, 0xBB, 0xCC]);
      expect(fragment.rawHex, 'd0 08 00 00 00 aa bb cc');
    });

    test('rejects non D0 packets and empty payloads', () {
      expect(EixamTelFragment.tryParse(<int>[0x01, 0x02, 0x03]), isNull);
      expect(
        EixamTelFragment.tryParse(<int>[0xD0, 0x03, 0x00, 0x00, 0x00]),
        isNull,
      );
    });
  });
}
