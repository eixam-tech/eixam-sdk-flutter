import 'package:eixam_connect_flutter/src/device/eixam_sos_over_tel_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const classifier = EixamSosOverTelClassifier();

  group('EixamSosOverTelClassifier', () {
    test('ordinary 12-byte TEL remains TEL', () {
      final decision = classifier.classify(_ordinaryTel);

      expect(decision.kind, EixamSosOverTelKind.tel);
      expect(decision.reason, 'tel_position_format_bit_set');
      expect(decision.isModernSos, isFalse);
    });

    test('modern 12-byte type-3 SOS-over-TEL is provable SOS', () {
      final decision = classifier.classify(_modernSosOverTel);

      expect(decision.kind, EixamSosOverTelKind.modernSos);
      expect(decision.reason, 'modern_sos_type_3');
      expect(decision.parsedSosType, 3);
      expect(decision.packetId, 7);
      expect(decision.originatorNodeId, 0x12345678);
    });

    test('malformed 12-byte values fail closed', () {
      final malformed = List<int>.of(_modernSosOverTel)..[4] = 0x100;
      final decision = classifier.classify(malformed);

      expect(decision.kind, EixamSosOverTelKind.malformed);
      expect(decision.reason, 'invalid_byte_domain');
      expect(decision.isModernSos, isFalse);
    });

    test('legacy-looking 12-byte packet stays TEL without hop proof', () {
      final legacy = List<int>.of(_modernSosOverTel)..[11] = 0x40;
      final decision = classifier.classify(legacy);

      expect(decision.kind, EixamSosOverTelKind.tel);
      expect(decision.reason, 'legacy_or_non_sos_without_hop_proof');
      expect(decision.parsedSosType, 1);
    });
  });
}

const List<int> _ordinaryTel = <int>[
  0x78,
  0x56,
  0x34,
  0x12,
  0x48,
  0xCD,
  0x1B,
  0x34,
  0x44,
  0x28,
  0x27,
  0x85,
];

const List<int> _modernSosOverTel = <int>[
  0x78,
  0x56,
  0x34,
  0x12,
  0x48,
  0xCD,
  0x1B,
  0x34,
  0x44,
  0x28,
  0x07,
  0xC0,
];
