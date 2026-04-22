import 'package:eixam_connect_flutter/src/device/eixam_cluster_heartbeat_packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EixamClusterHeartbeatPacket', () {
    test('parses the v2 12-byte heartbeat layout with uint32 aggId', () {
      final packet = EixamClusterHeartbeatPacket.tryParse(
        const <int>[
          0x78,
          0x56,
          0x34,
          0x12,
          0x9A,
          0xCD,
          0xAB,
          0xEF,
          0xCD,
          0xAB,
          0x89,
          0x57,
        ],
      );

      expect(packet, isNotNull);
      expect(packet!.nodeId, 0x12345678);
      expect(packet.score, 0x9A);
      expect(packet.clusterId, 0xABCD);
      expect(packet.aggId, 0x89ABCDEF);
      expect(packet.memberCount, 5);
      expect(packet.aggSpreadingFactor, 7);
    });

    test('rejects payloads that do not match the fixed 12-byte layout', () {
      expect(
        EixamClusterHeartbeatPacket.tryParse(const <int>[0x01, 0x02, 0x03]),
        isNull,
      );
    });
  });
}
