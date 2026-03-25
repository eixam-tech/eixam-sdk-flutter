import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EixamGuidedRescueStatusPacket', () {
    test('decodes STATUS_RESP into a structured rescue snapshot', () {
      final receivedAt = DateTime.utc(2026, 3, 25, 10);
      final packet = EixamGuidedRescueStatusPacket.tryParse(
        const <int>[
          0x02,
          0x20,
          0x01,
          0x10,
          0x85,
          0x02,
          0x03,
          0x03,
          0x02,
          0x03,
        ],
        receivedAt: receivedAt,
      );

      expect(packet, isNotNull);
      expect(packet!.rescueNodeId, 0x2002);
      expect(packet.victimNodeId, 0x1001);
      expect(packet.targetState, GuidedRescueTargetState.active);
      expect(packet.batteryLevel, DeviceBatteryLevel.ok);
      expect(packet.gpsQuality, 3);
      expect(packet.retryCount, 2);
      expect(packet.relayPendingAck, isTrue);
      expect(packet.internetAvailable, isTrue);

      final snapshot = packet.toSnapshot();
      expect(snapshot.targetNodeId, 0x1001);
      expect(snapshot.rescueNodeId, 0x2002);
      expect(snapshot.targetState, GuidedRescueTargetState.active);
      expect(snapshot.batteryLevel, DeviceBatteryLevel.ok);
      expect(snapshot.gpsQuality, 3);
      expect(snapshot.retryCount, 2);
      expect(snapshot.relayPendingAck, isTrue);
      expect(snapshot.internetAvailable, isTrue);
      expect(snapshot.receivedAt, receivedAt);
    });

    test('rejects payloads that do not match STATUS_RESP semantics', () {
      expect(
        EixamGuidedRescueStatusPacket.tryParse(
          const <int>[
            0x01,
            0x10,
            0x02,
            0x20,
            0x84,
            0x02,
            0x03,
            0x03,
            0x00,
            0x00
          ],
        ),
        isNull,
      );
      expect(
        EixamGuidedRescueStatusPacket.tryParse(
          const <int>[
            0x01,
            0x10,
            0x02,
            0x20,
            0x85,
            0x02,
            0x04,
            0x03,
            0x00,
            0x00
          ],
        ),
        isNull,
      );
    });
  });
}
