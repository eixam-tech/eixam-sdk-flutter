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

    test('setRegion encodes opcode 0x20 plus the region byte', () {
      expect(EixamDeviceCommand.setRegion(3).encode(), <int>[0x20, 0x03]);
      expect(EixamDeviceCommand.setRegion(1).encode(), <int>[0x20, 0x01]);
      // Masks the region byte to a single octet.
      expect(EixamDeviceCommand.setRegion(0x1FF).encode(), <int>[0x20, 0xFF]);
    });

    test('setRegion is critical and forced onto the CMD characteristic', () {
      final command = EixamDeviceCommand.setRegion(3);

      expect(command.opcode, 0x20);
      expect(command.isCritical, isTrue);
      expect(command.usesCmdCharacteristic, isTrue);
    });

    test('encodes the fixed persistent position backlog commands', () {
      expect(
        EixamDeviceCommand.positionBacklogStart(
          sinceUnix: 0x12345678,
          maxEvents: 0x9ABC,
        ).encode(),
        <int>[0x30, 0x78, 0x56, 0x34, 0x12, 0xBC, 0x9A],
      );
      expect(
        EixamDeviceCommand.positionBacklogAck(
          sessionId: 7,
          nextLogicalIndex: 0x12345678,
        ).encode(),
        <int>[0x31, 7, 0x78, 0x56, 0x34, 0x12],
      );
      expect(
        EixamDeviceCommand.positionBacklogAbort(sessionId: 7, reason: 3)
            .encode(),
        <int>[0x32, 7, 3],
      );
    });

    test('redacts persistent position backlog command diagnostics', () {
      final commands = <EixamDeviceCommand>[
        EixamDeviceCommand.positionBacklogStart(sinceUnix: 0x12345678),
        EixamDeviceCommand.positionBacklogAck(
          sessionId: 7,
          nextLogicalIndex: 0x12345678,
        ),
        EixamDeviceCommand.positionBacklogAbort(sessionId: 7, reason: 3),
      ];

      for (final command in commands) {
        expect(command.diagnosticPayload, '<redacted-operational-payload>');
        expect(command.diagnosticPayload, isNot(contains('12345678')));
      }
    });
  });
}
