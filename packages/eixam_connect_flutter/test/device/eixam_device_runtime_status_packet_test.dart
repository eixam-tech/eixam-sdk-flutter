import 'package:eixam_connect_flutter/src/device/eixam_device_runtime_status_packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EixamDeviceRuntimeStatusPacket', () {
    test('parses a valid 12-byte runtime status payload', () {
      final receivedAt = DateTime.utc(2026, 4, 18, 10);
      final packet = EixamDeviceRuntimeStatusPacket.tryParse(
        const <int>[
          0xE9,
          0x78,
          0x01,
          0x02,
          0x03,
          0x07,
          0x1F,
          0x34,
          0x12,
          88,
          0x3C,
          0x00,
        ],
        receivedAt: receivedAt,
      );

      expect(packet, isNotNull);
      expect(packet!.status.region, 2);
      expect(packet.status.modemPreset, 3);
      expect(packet.status.meshSpreadingFactor, 7);
      expect(packet.status.isProvisioned, isTrue);
      expect(packet.status.usePreset, isTrue);
      expect(packet.status.txEnabled, isTrue);
      expect(packet.status.inetOk, isTrue);
      expect(packet.status.positionConfirmed, isTrue);
      expect(packet.status.nodeId, 0x1234);
      expect(packet.status.batteryPercent, 88);
      expect(packet.status.telIntervalSeconds, 60);
      expect(packet.status.receivedAt, receivedAt);
    });

    test('rejects packets with an unexpected header or length', () {
      expect(
        EixamDeviceRuntimeStatusPacket.tryParse(
          const <int>[0xE9, 0x78, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        ),
        isNull,
      );
      expect(
        EixamDeviceRuntimeStatusPacket.tryParse(
          const <int>[0xE9, 0x78, 0x01, 0x02],
        ),
        isNull,
      );
    });
  });
}
