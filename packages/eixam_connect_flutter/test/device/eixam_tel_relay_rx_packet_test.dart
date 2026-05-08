import 'package:eixam_connect_flutter/src/device/eixam_tel_relay_rx_packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EixamTelRelayRxPacket', () {
    test('rejects payloads that do not match the D2 relay contract', () {
      expect(
        EixamTelRelayRxPacket.tryParse(
          const <int>[0xD2, 0x01, 0x02, 0x03],
        ),
        isNull,
      );
      expect(
        EixamTelRelayRxPacket.tryParse(
          const <int>[
            0xD1,
            0xA8,
            0x1A,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x01,
            0x21,
            0xF6,
            0xC4,
            0xB0,
            0x1B,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x01,
            0x21,
            0x87,
            0x65,
          ],
        ),
        isNull,
      );
    });
  });
}
