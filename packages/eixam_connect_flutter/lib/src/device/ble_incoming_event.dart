import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'eixam_ble_protocol.dart';
import 'eixam_sos_packet.dart';
import 'eixam_tel_packet.dart';

class BleIncomingEvent {
  const BleIncomingEvent({
    required this.deviceId,
    required this.eventType,
    required this.channel,
    required this.payload,
    required this.payloadHex,
    required this.source,
    required this.receivedAt,
    this.deviceAlias,
    this.telPacket,
    this.sosPacket,
  });

  final String deviceId;
  final String? deviceAlias;
  final String eventType;
  final EixamBleChannel channel;
  final List<int> payload;
  final String payloadHex;
  final DeviceSosTransitionSource source;
  final DateTime receivedAt;
  final EixamTelPacket? telPacket;
  final EixamSosPacket? sosPacket;
}
