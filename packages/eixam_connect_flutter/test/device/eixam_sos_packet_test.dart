import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EixamSosPacket.tryParse', () {
    test('parses a minimal 5-byte SOS packet', () {
      final packet = EixamSosPacket.tryParse(<int>[
        0x34,
        0x12,
        0xA5,
        0xB1,
        0x09,
      ]);

      expect(packet, isNotNull);
      expect(packet!.nodeId, 0x1234);
      expect(packet.hasPosition, isFalse);
      expect(packet.sequence, 0x09);
      expect(packet.sosType, ((0xB1A5 >> 14) & 0x03));
      expect(packet.packetId, 0x05);
    });

    test('rejects invalid packet lengths', () {
      expect(EixamSosPacket.tryParse(<int>[0x01, 0x02, 0x03]), isNull);
    });
  });
}
