import 'package:eixam_connect_flutter/src/device/eixam_tel_fragment.dart';
import 'package:eixam_connect_flutter/src/device/eixam_tel_reassembler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EixamTelReassembler', () {
    test('completes an aggregate from out-of-order fragments', () {
      final reassembler = EixamTelReassembler();
      final second = EixamTelFragment.tryParse(<int>[
        0xD0,
        0x06,
        0x00,
        0x03,
        0x00,
        0xDD,
        0xEE,
        0xFF,
      ])!;
      final first = EixamTelFragment.tryParse(<int>[
        0xD0,
        0x06,
        0x00,
        0x00,
        0x00,
        0xAA,
        0xBB,
        0xCC,
      ])!;

      expect(reassembler.addFragment(second), isNull);
      expect(
        reassembler.addFragment(first),
        <int>[0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF],
      );
    });

    test('rejects overlapping fragments defensively', () {
      final reassembler = EixamTelReassembler();
      final first = EixamTelFragment.tryParse(<int>[
        0xD0,
        0x06,
        0x00,
        0x00,
        0x00,
        0xAA,
        0xBB,
        0xCC,
      ])!;
      final overlap = EixamTelFragment.tryParse(<int>[
        0xD0,
        0x06,
        0x00,
        0x02,
        0x00,
        0xCC,
        0xDD,
      ])!;

      expect(reassembler.addFragment(first), isNull);
      expect(reassembler.addFragment(overlap), isNull);
      expect(
        reassembler.addFragment(first),
        isNull,
        reason: 'the reassembler should reset after invalid overlap',
      );
    });
  });
}
