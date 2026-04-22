import 'package:eixam_connect_flutter/src/device/eixam_sos_packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EixamSosPacket.tryParse', () {
    test('parses a minimal 7-byte SOS packet', () {
      final packet = EixamSosPacket.tryParse(<int>[
        0x34,
        0x12,
        0x00,
        0x00,
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

    test('parses remote deviceId from the extended SOS relay contract', () {
      final packet = EixamSosPacket.tryParse(<int>[
        0x34,
        0x12,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x54,
        0xCF,
        0x82,
        0x10,
        0x20,
        0x30,
        0x41,
      ]);

      expect(packet, isNotNull);
      expect(packet!.relayCount, 1);
      expect(packet.remoteDeviceId, 'CF:82:10:20:30:41');
    });
  });
}
