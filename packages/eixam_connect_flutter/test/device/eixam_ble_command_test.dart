import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EixamDeviceCommand', () {
    test('encodes SOS_ACK_RELAY as opcode plus uint32 nodeId', () {
      final command = EixamDeviceCommand.sosAckRelay(nodeId: 0x12345678);

      expect(command.bytes, <int>[0x08, 0x78, 0x56, 0x34, 0x12]);
    });
  });
}
