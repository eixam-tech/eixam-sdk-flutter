import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/eixam_position_data.dart';
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

    test('parses a 10-byte SOS delta without inventing a fix', () {
      final flags = EixamSosPacket.packFlags(sosType: 2);
      final packet = EixamSosPacket.tryParse(<int>[
        0x34,
        0x12,
        0x00,
        0x00,
        flags & 0xFF,
        (flags >> 8) & 0xFF,
        0x07,
        0x00,
        0x10,
        0x02,
      ]);

      expect(packet, isNotNull);
      expect(packet!.format, EixamSosPacketFormat.delta);
      expect(packet.isActiveSos, isTrue);
      expect(packet.hasValidPosition, isFalse);
      expect(packet.sequence, 0x07);
      expect(packet.deltaLatMeters, isNotNull);
    });

    test('12-byte TEL at speed is not SOS; Null Island is not a fix', () {
      final telAtSpeedFlags = EixamSosPacket.packFlags(
        sosType: 1,
        speedEstimate: 2,
      );
      expect((telAtSpeedFlags & 0x0020) != 0, isTrue);
      final tel = EixamSosPacket.tryParse(<int>[
        0x34,
        0x12,
        0x00,
        0x00,
        ...EixamPositionData.encode(latitude: 42.5, longitude: 1.5),
        telAtSpeedFlags & 0xFF,
        (telAtSpeedFlags >> 8) & 0xFF,
      ]);
      expect(tel, isNotNull);
      expect(tel!.formatBitIsTelPosition, isTrue);
      expect(tel.isActiveSos, isFalse);

      final sosFlags = EixamSosPacket.packFlags(sosType: 2);
      final nullIsland = EixamSosPacket.tryParse(<int>[
        0x34,
        0x12,
        0x00,
        0x00,
        ...EixamPositionData.encode(latitude: 0, longitude: 0),
        sosFlags & 0xFF,
        (sosFlags >> 8) & 0xFF,
      ]);
      expect(nullIsland, isNotNull);
      expect(nullIsland!.isActiveSos, isTrue);
      expect(nullIsland.hasValidPosition, isFalse);
      expect(nullIsland.trackingPositionAt(DateTime.utc(2026, 9, 1)), isNull);
      expect(tel.isActiveOnChannel(EixamBleChannel.sos), isTrue);
      expect(tel.isActiveOnChannel(EixamBleChannel.tel), isFalse);

      final type3 = EixamSosPacket.tryParse(<int>[
        0x34,
        0x12,
        0x00,
        0x00,
        ...() {
          final flags = EixamSosPacket.packFlags(sosType: 3);
          return <int>[flags & 0xFF, (flags >> 8) & 0xFF, 0x01];
        }(),
      ]);
      expect(type3!.isClear, isFalse);
      expect(type3.isActiveSos, isTrue);
      expect(type3.hasValidPosition, isFalse);
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
