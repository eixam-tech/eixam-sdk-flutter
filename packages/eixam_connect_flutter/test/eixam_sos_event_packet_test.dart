import 'package:eixam_connect_flutter/src/device/eixam_sos_event_packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EixamSosEventPacket.tryParse', () {
    test('parses valid SOS device events', () {
      final packet = EixamSosEventPacket.tryParse(
        <int>[0xE1, 0x02, 0x34, 0x12, 0x00, 0x00],
      );

      expect(packet, isNotNull);
      expect(packet!.opcode, 0xE1);
      expect(packet.subcode, 0x02);
      expect(packet.nodeId, 0x1234);
      expect(packet.isUserDeactivated, isTrue);
      expect(packet.isAppCancelAck, isFalse);
    });

    test('parses backend-resolved ACK_SOS events', () {
      final packet = EixamSosEventPacket.tryParse(
        <int>[0xE3, 0x01, 0x34, 0x12, 0x00, 0x00],
      );

      expect(packet, isNotNull);
      expect(packet!.isBackendResolved, isTrue);
      expect(packet.isUserDeactivated, isFalse);
      expect(packet.nodeId, 0x1234);
    });

    test('rejects packets with invalid size or opcode', () {
      expect(EixamSosEventPacket.tryParse(<int>[0xE1, 0x01, 0x34]), isNull);
      expect(
        EixamSosEventPacket.tryParse(<int>[0xE4, 0x01, 0x34, 0x12, 0x00, 0x00]),
        isNull,
      );
    });
  });
}
