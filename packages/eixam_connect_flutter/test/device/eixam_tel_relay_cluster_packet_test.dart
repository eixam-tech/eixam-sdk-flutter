import 'package:eixam_connect_flutter/src/device/eixam_tel_relay_cluster_packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EixamTelRelayClusterPacket', () {
    test('fans out one telemetry member per remote device in a C2 payload', () {
      final packet = EixamTelRelayClusterPacket.tryParse(
        const <int>[
          0xC2,
          0x02,
          0xCF,
          0x82,
          0x10,
          0x20,
          0x30,
          0x40,
          0x34,
          0x12,
          0x01,
          0x02,
          0x03,
          0x04,
          0x05,
          0x06,
          0x87,
          0x65,
          0xCF,
          0x82,
          0x10,
          0x20,
          0x30,
          0x41,
          0x35,
          0x12,
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
      expect(packet!.members, hasLength(2));
      expect(packet.members.first.remoteDeviceId, 'CF:82:10:20:30:40');
      expect(packet.members.last.remoteDeviceId, 'CF:82:10:20:30:41');
    });
  });
}
