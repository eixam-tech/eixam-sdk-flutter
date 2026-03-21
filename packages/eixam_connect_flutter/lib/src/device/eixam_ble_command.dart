import 'eixam_ble_protocol.dart';

class EixamDeviceCommand {
  const EixamDeviceCommand._({
    required this.opcode,
    required this.label,
    this.payload = const <int>[],
  });

  final int opcode;
  final String label;
  final List<int> payload;

  factory EixamDeviceCommand.inetOk() =>
      const EixamDeviceCommand._(opcode: 0x01, label: 'INET OK');

  factory EixamDeviceCommand.inetLost() =>
      const EixamDeviceCommand._(opcode: 0x02, label: 'INET LOST');

  factory EixamDeviceCommand.positionConfirmed() =>
      const EixamDeviceCommand._(opcode: 0x03, label: 'POS CONFIRMED');

  factory EixamDeviceCommand.sosCancel() =>
      const EixamDeviceCommand._(opcode: 0x04, label: 'SOS CANCEL');

  factory EixamDeviceCommand.sosConfirm() =>
      const EixamDeviceCommand._(opcode: 0x05, label: 'SOS CONFIRM');

  factory EixamDeviceCommand.sosTriggerApp() =>
      const EixamDeviceCommand._(opcode: 0x06, label: 'SOS TRIGGER APP');

  factory EixamDeviceCommand.sosAck() =>
      const EixamDeviceCommand._(opcode: 0x07, label: 'SOS ACK');

  factory EixamDeviceCommand.sosAckRelay({required int nodeId}) {
    return EixamDeviceCommand._(
      opcode: 0x08,
      label: 'SOS ACK RELAY',
      payload: <int>[nodeId & 0xFF, (nodeId >> 8) & 0xFF],
    );
  }

  factory EixamDeviceCommand.shutdown() =>
      const EixamDeviceCommand._(opcode: 0x10, label: 'SHUTDOWN');

  List<int> encode() => <int>[opcode, ...payload];

  bool get usesCmdCharacteristic =>
      encode().length > EixamBleProtocol.inetMaxPayloadLength;

  String get targetCharacteristicUuid => usesCmdCharacteristic
      ? EixamBleProtocol.cmdWriteCharacteristicUuid
      : EixamBleProtocol.inetWriteCharacteristicUuid;

  String get encodedHex => EixamBleProtocol.hex(encode());
}
