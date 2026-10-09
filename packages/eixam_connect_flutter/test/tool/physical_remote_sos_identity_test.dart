import 'package:flutter_test/flutter_test.dart';

import '../../lib/src/device/eixam_sos_packet.dart';
import '../../tool/qa/physical_remote_sos_identity.dart';

void main() {
  test('QA identity uses SDK-decoded origin and packet correlation', () {
    final payload = minimal(nodeId: 0x12345678, sosType: 3, packetId: 7);
    final identity = physicalRemoteSosIdentity({
      'raw_payload': payload,
      'origin_device': 0x12345678,
      'relay_device': 42,
    });
    expect(identity['packet_id'], 7);
    expect(identity['wire_cycle_correlation'], '305419896:7');
  });

  test(
    'wrong origin, origin-as-relay, clear and malformed payload cannot pass',
    () {
      final open = minimal(nodeId: 42, sosType: 3);
      for (final input in <Map<String, dynamic>>[
        {'raw_payload': open, 'origin_device': 41, 'relay_device': 1},
        {'raw_payload': open, 'origin_device': 42, 'relay_device': 42},
        {
          'raw_payload': minimal(nodeId: 42, sosType: 0),
          'origin_device': 42,
          'relay_device': 1,
        },
        {
          'raw_payload': [999],
          'origin_device': 42,
          'relay_device': 1,
        },
        {'raw_payload': [], 'origin_device': 42, 'relay_device': 1},
      ]) {
        expect(() => physicalRemoteSosIdentity(input), throwsFormatException);
      }
    },
  );
}

List<int> minimal({
  required int nodeId,
  required int sosType,
  int packetId = 0,
}) {
  final flags = EixamSosPacket.packFlags(sosType: sosType, packetId: packetId);
  return [
    for (var byte = 0; byte < 4; byte++) (nodeId >> (byte * 8)) & 255,
    flags & 255,
    (flags >> 8) & 255,
    1,
  ];
}
