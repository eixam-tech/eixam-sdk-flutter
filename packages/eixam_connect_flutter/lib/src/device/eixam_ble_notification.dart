import 'eixam_ble_protocol.dart';

class EixamBleNotification {
  EixamBleNotification({
    required this.channel,
    required this.payload,
    required this.receivedAt,
  }) : payloadHex = EixamBleProtocol.hex(payload);

  final EixamBleChannel channel;
  final List<int> payload;
  final String payloadHex;
  final DateTime receivedAt;
}
