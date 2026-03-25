import 'eixam_ble_protocol.dart';

class EixamDeviceCommand {
  const EixamDeviceCommand._({
    required this.opcode,
    required this.label,
    required this.bytes,
    this.forceCmdCharacteristic = false,
  });

  final int opcode;
  final String label;
  final List<int> bytes;
  final bool forceCmdCharacteristic;

  factory EixamDeviceCommand.inetOk() => const EixamDeviceCommand._(
        opcode: 0x01,
        label: 'INET OK',
        bytes: <int>[0x01],
      );

  factory EixamDeviceCommand.inetLost() => const EixamDeviceCommand._(
        opcode: 0x02,
        label: 'INET LOST',
        bytes: <int>[0x02],
      );

  factory EixamDeviceCommand.positionConfirmed() => const EixamDeviceCommand._(
        opcode: 0x03,
        label: 'POS CONFIRMED',
        bytes: <int>[0x03],
      );

  factory EixamDeviceCommand.sosCancel() => const EixamDeviceCommand._(
        opcode: 0x04,
        label: 'SOS CANCEL',
        bytes: <int>[0x04],
      );

  factory EixamDeviceCommand.sosConfirm() => const EixamDeviceCommand._(
        opcode: 0x05,
        label: 'SOS CONFIRM',
        bytes: <int>[0x05],
      );

  factory EixamDeviceCommand.sosTriggerApp() => const EixamDeviceCommand._(
        opcode: 0x06,
        label: 'SOS TRIGGER APP',
        bytes: <int>[0x06],
      );

  factory EixamDeviceCommand.sosAck() => const EixamDeviceCommand._(
        opcode: 0x07,
        label: 'SOS ACK',
        bytes: <int>[0x07],
      );

  factory EixamDeviceCommand.sosAckRelay({required int nodeId}) {
    return EixamDeviceCommand._(
      opcode: 0x08,
      label: 'SOS ACK RELAY',
      bytes: <int>[0x08, nodeId & 0xFF, (nodeId >> 8) & 0xFF],
    );
  }

  factory EixamDeviceCommand.shutdown() => const EixamDeviceCommand._(
        opcode: 0x10,
        label: 'SHUTDOWN',
        bytes: <int>[0x10],
      );

  factory EixamDeviceCommand.guidedRescue({
    required int targetNodeId,
    required int rescueNodeId,
    required int commandCode,
    required String label,
  }) {
    return EixamDeviceCommand._(
      opcode: commandCode,
      label: label,
      bytes: <int>[
        targetNodeId & 0xFF,
        (targetNodeId >> 8) & 0xFF,
        rescueNodeId & 0xFF,
        (rescueNodeId >> 8) & 0xFF,
        commandCode,
      ],
      forceCmdCharacteristic: true,
    );
  }

  List<int> encode() => List<int>.unmodifiable(bytes);

  bool get usesCmdCharacteristic =>
      forceCmdCharacteristic ||
      encode().length > EixamBleProtocol.inetMaxPayloadLength;

  String get targetCharacteristicUuid => usesCmdCharacteristic
      ? EixamBleProtocol.cmdWriteCharacteristicUuid
      : EixamBleProtocol.inetWriteCharacteristicUuid;

  String get encodedHex => EixamBleProtocol.hex(encode());
}
