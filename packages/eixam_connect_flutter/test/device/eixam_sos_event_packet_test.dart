import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EixamSosEventPacket.tryParse', () {
    test('parses user-deactivated event packets', () {
      final packet = EixamSosEventPacket.tryParse(<int>[0xE1, 0x02, 0x34, 0x12]);

      expect(packet, isNotNull);
      expect(packet!.isUserDeactivated, isTrue);
      expect(packet.isAppCancelAck, isFalse);
      expect(packet.subcode, 0x02);
      expect(packet.nodeId, 0x1234);
    });

    test('rejects unsupported opcodes', () {
      expect(EixamSosEventPacket.tryParse(<int>[0xE3, 0x00, 0x00, 0x00]), isNull);
    });
  });
}
