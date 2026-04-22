import 'package:eixam_connect_flutter/src/device/eixam_tel_relay_cluster_packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EixamTelRelayClusterPacket', () {
    test('parses a v2 C2 aggregate with 12-byte TEL members', () {
      final packet = EixamTelRelayClusterPacket.tryParse(
        const <int>[
          0xC2,
          0x02,
          0x01,
          0x02,
          0x34,
          0x12,
          0x00,
          0x00,
          0x01,
          0x02,
          0x03,
          0x04,
          0x05,
          0x06,
          0x87,
          0x65,
          0x35,
          0x12,
          0x00,
          0x00,
          0x01,
          0x02,
          0x03,
          0x04,
          0x05,
          0x06,
          0x87,
          0x65,
        ],
      );

      expect(packet, isNotNull);
      expect(packet!.clusterId, 0x0102);
      expect(packet.members, hasLength(2));
      expect(packet.members.first.packet.nodeId, 0x1234);
      expect(packet.members.last.packet.nodeId, 0x1235);
    });
  });
}
