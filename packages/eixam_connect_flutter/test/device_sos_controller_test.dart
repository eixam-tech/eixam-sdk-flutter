import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_event_packet.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeviceSosController.handleIncomingSosEventPacket', () {
    test('maps user deactivated subcode 0x01 to inactive', () {
      final controller = DeviceSosController();

      controller.handleIncomingSosEventPacket(
        EixamSosEventPacket.tryParse(<int>[0xE1, 0x01, 0x34, 0x12])!,
        source: DeviceSosTransitionSource.device,
      );

      final status = controller.currentStatus;
      expect(status.state, DeviceSosState.inactive);
      expect(status.previousState, DeviceSosState.inactive);
      expect(status.optimistic, isFalse);
      expect(status.derivedFromBlePacket, isTrue);
      expect(status.nodeId, 0x1234);
      expect(status.lastPacketLength, 4);
      expect(status.lastPacketHex, 'e1 01 34 12');
      expect(status.decoderNote, contains('user deactivated'));
    });

    test('maps app cancel ack subcode 0x03 to resolved', () {
      final controller = DeviceSosController();
      final activePacket = EixamSosPacket.tryParse(<int>[
        0x34,
        0x12,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x40,
      ])!;

      controller.handleIncomingSosPacket(
        activePacket,
        source: DeviceSosTransitionSource.device,
      );
      controller.handleIncomingSosEventPacket(
        EixamSosEventPacket.tryParse(<int>[0xE2, 0x03, 0x34, 0x12])!,
        source: DeviceSosTransitionSource.app,
      );

      final status = controller.currentStatus;
      expect(status.state, DeviceSosState.resolved);
      expect(status.previousState, DeviceSosState.active);
      expect(status.transitionSource, DeviceSosTransitionSource.app);
      expect(status.nodeId, 0x1234);
      expect(status.lastPacketHex, 'e2 03 34 12');
      expect(status.decoderNote, contains('app cancel acknowledged'));
    });
  });
}
