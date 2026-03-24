import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EixamTelReassembler', () {
    test('reassembles fragments into a complete blob', () {
      final reassembler = EixamTelReassembler();
      final first = EixamTelFragment.tryParse(<int>[
        0xD0,
        0x06,
        0x00,
        0x00,
        0x00,
        0x10,
        0x11,
        0x12,
      ])!;
      final second = EixamTelFragment.tryParse(<int>[
        0xD0,
        0x06,
        0x00,
        0x03,
        0x00,
        0x13,
        0x14,
        0x15,
      ])!;

      expect(reassembler.addFragment(first), isNull);
      expect(reassembler.addFragment(second), <int>[0x10, 0x11, 0x12, 0x13, 0x14, 0x15]);
    });

    test('returns null and resets on conflicting overlapping fragments', () {
      final reassembler = EixamTelReassembler();
      final first = EixamTelFragment.tryParse(<int>[
        0xD0,
        0x04,
        0x00,
        0x00,
        0x00,
        0xAA,
        0xBB,
      ])!;
      final conflict = EixamTelFragment.tryParse(<int>[
        0xD0,
        0x04,
        0x00,
        0x01,
        0x00,
        0xCC,
        0xDD,
      ])!;

      expect(reassembler.addFragment(first), isNull);
      expect(reassembler.addFragment(conflict), isNull);
      expect(reassembler.addFragment(first), isNull);
    });
  });
}
