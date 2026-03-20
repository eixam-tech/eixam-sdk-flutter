import 'package:eixam_connect_core/eixam_connect_core.dart';

class BleIncomingEvent {
  const BleIncomingEvent({
    required this.deviceId,
    required this.eventType,
    required this.payload,
    required this.payloadHex,
    required this.source,
    required this.receivedAt,
    this.deviceAlias,
  });

  final String deviceId;
  final String? deviceAlias;
  final String eventType;
  final List<int> payload;
  final String payloadHex;
  final DeviceSosTransitionSource source;
  final DateTime receivedAt;
}
