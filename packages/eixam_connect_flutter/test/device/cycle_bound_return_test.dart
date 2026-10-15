import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_payload_classifier.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_packet.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';

void main() {
  const receipt = <int>[
    0xE4,
    1,
    0x44,
    0x33,
    0x22,
    0x11,
    7,
    1,
    0xA8,
    0x1A,
    0x4B,
    0x59,
    0,
    0xC0,
    0,
  ];
  test(
    'v1 receipt keeps actual mesh identity distinct from 4-bit SOS counter',
    () {
      final packet = EixamSosPacket.tryParse(receipt)!;
      expect(packet.nodeId, 0x594B1AA8);
      expect(packet.originPacketId, 0x11223344);
      expect(packet.packetId, 0);
      expect(packet.isActiveSos, isTrue);
      expect(packet.hasPosition, isFalse);
      expect(packet.rawBytes, receipt.sublist(8));
      for (final index in <int>[1, 6, 7]) {
        final malformed = List<int>.from(receipt)..[index] = 0;
        expect(EixamSosPacket.tryParse(malformed), isNull);
      }
      final zero = List<int>.from(receipt)..setRange(2, 6, <int>[0, 0, 0, 0]);
      expect(EixamSosPacket.tryParse(zero), isNull);
      for (var length = 0; length < receipt.length; length++) {
        expect(
          EixamSosPacket.tryParse(receipt.sublist(0, length))?.originPacketId,
          isNull,
        );
      }
    },
  );
  test(
    'bound remote receipt cannot project the relay as its logical SOS origin',
    () {
      final c = const BleIncomingPayloadClassifier().classifySosPayload(
        payload: receipt,
        payloadHex: EixamBleProtocol.hex(receipt),
        receivedAt: DateTime.utc(2026),
        source: DeviceSosTransitionSource.device,
        channel: EixamBleChannel.sos,
        connectedBleTagNodeId: 0x594B1AA8,
        fallbackOnUnknownConnectedNode: const BleIncomingPayloadClassification(
          kind: BleIncomingPayloadKind.unknown,
        ),
      );
      expect(c.kind, BleIncomingPayloadKind.unknown);
      expect(c.remoteRelaySosSnapshot, isNull);
    },
  );
  test(
    'return command validates uint32 references and selects terminal semantics',
    () {
      for (final terminal in <bool>[false, true]) {
        final c = EixamDeviceCommand.boundSosReturn(
          nodeId: 0x594B1AA8,
          originPacketId: 0x11223344,
          terminal: terminal,
        );
        expect(c.encode(), <int>[
          0x0B,
          1,
          terminal ? 2 : 4,
          0xA8,
          0x1A,
          0x4B,
          0x59,
          0x44,
          0x33,
          0x22,
          0x11,
        ]);
        expect(c.forceCmdCharacteristic, isTrue);
        expect(c.isCritical, isTrue);
      }
      for (final id in <int>[0, -1, 0x100000000]) {
        expect(
          () => EixamDeviceCommand.boundSosReturn(
            nodeId: 1,
            originPacketId: id,
            terminal: false,
          ),
          throwsArgumentError,
        );
      }
    },
  );
  test(
    'remote return writer never changes the connected relay SOS state',
    () async {
      final c = DeviceSosController();
      final writes = <EixamDeviceCommand>[];
      await c.attach(
        commandWriter: (command) async {
          writes.add(command);
        },
      );
      c.handleIncomingSosPacket(
        EixamSosPacket.tryParse(<int>[0x6E, 0x75, 0x93, 0x55, 0, 0xC0, 0])!,
        source: DeviceSosTransitionSource.device,
      );
      await c.confirmSos();
      writes.clear();
      expect(c.currentStatus.state, DeviceSosState.active);
      final before = c.currentStatus;
      for (final terminal in <bool>[false, true, true]) {
        await c.sendBoundRelayReturn(
          nodeId: 0x594B1AA8,
          originPacketId: 0x11223344,
          terminal: terminal,
        );
        expect(c.currentStatus, before);
      }
      expect(writes, hasLength(3));
      await c.dispose();
    },
  );
}
