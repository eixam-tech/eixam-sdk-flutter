import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EixamDeviceCommand', () {
    test('encodes SOS_ACK_RELAY as opcode plus uint32 nodeId', () {
      final command = EixamDeviceCommand.sosAckRelay(nodeId: 0x12345678);

      expect(command.bytes, <int>[0x08, 0x78, 0x56, 0x34, 0x12]);
    });

    test('existing command encoding remains unchanged', () {
      expect(EixamDeviceCommand.inetOk().encode(), <int>[0x01]);
      expect(EixamDeviceCommand.inetLost().encode(), <int>[0x02]);
      expect(EixamDeviceCommand.positionConfirmed().encode(), <int>[0x03]);
      expect(EixamDeviceCommand.sosCancel().encode(), <int>[0x04]);
      expect(EixamDeviceCommand.sosConfirm().encode(), <int>[0x05]);
      expect(EixamDeviceCommand.sosTriggerApp().encode(), <int>[0x06]);
      expect(EixamDeviceCommand.sosAck().encode(), <int>[0x07]);
      expect(EixamDeviceCommand.shutdown().encode(), <int>[0x10]);
      expect(EixamDeviceCommand.notificationVolume(80).encode(), <int>[
        0x11,
        80,
      ]);
      expect(EixamDeviceCommand.sosVolume(70).encode(), <int>[0x12, 70]);
      expect(EixamDeviceCommand.reboot().encode(), <int>[0x22]);
      expect(EixamDeviceCommand.getDeviceStatus().encode(), <int>[0x23]);
    });
  });
}
