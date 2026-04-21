import 'package:eixam_connect_flutter/src/device/eixam_tel_relay_rx_packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EixamTelRelayRxPacket', () {
    test('parses typed relay telemetry from a completed D2 payload', () {
      final receivedAt = DateTime.utc(2026, 4, 18, 11);
      final packet = EixamTelRelayRxPacket.tryParse(
        const <int>[
          0xD2,
          0xA8,
          0x1A,
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
          0x01,
          0x21,
        ],
        receivedAt: receivedAt,
      );

      expect(packet, isNotNull);
      expect(packet!.relay.rxSnr, -10);
      expect(packet.relay.rxRssi, -60);
      expect(packet.relay.peerPayload, hasLength(10));
      expect(packet.relay.selfPayload, hasLength(10));
      expect(packet.relay.peerPosition.source.name, 'mesh');
      expect(packet.relay.selfPosition.source.name, 'mesh');
      expect(packet.relay.receivedAt, receivedAt);
    });

    test('parses remote deviceId from the extended D2 relay contract', () {
      final packet = EixamTelRelayRxPacket.tryParse(
        const <int>[
          0xD2,
          0xA8,
          0x1A,
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
          0x01,
          0x21,
          0xCF,
          0x82,
          0x10,
          0x20,
          0x30,
          0x40,
        ],
      );

      expect(packet, isNotNull);
      expect(packet!.relay.remoteDeviceId, 'CF:82:10:20:30:40');
    });

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
            0x01,
            0x21,
          ],
        ),
        isNull,
      );
    });
  });
}
