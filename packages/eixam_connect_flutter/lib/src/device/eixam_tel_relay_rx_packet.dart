import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'eixam_tel_packet.dart';

class EixamTelRelayRxPacket {
  const EixamTelRelayRxPacket({
    required this.payload,
    required this.relay,
  });

  static const int opcode = 0xD2;
  static const int payloadLength = 23;

  final List<int> payload;
  final DeviceTelRelayRx relay;

  static EixamTelRelayRxPacket? tryParse(
    List<int> bytes, {
    DateTime? receivedAt,
  }) {
    if (bytes.length != payloadLength || bytes.first != opcode) {
      return null;
    }

    final peerPayload = List<int>.unmodifiable(bytes.sublist(1, 11));
    final peerPacket = EixamTelPacket.tryParse(peerPayload);
    if (peerPacket == null) {
      return null;
    }

    final rxSnr = bytes[11] >= 0x80 ? bytes[11] - 0x100 : bytes[11];
    final rxRssi = bytes[12] >= 0x80 ? bytes[12] - 0x100 : bytes[12];

    final selfPayload = List<int>.unmodifiable(bytes.sublist(13, 23));
    final selfPacket = EixamTelPacket.tryParse(selfPayload);
    if (selfPacket == null) {
      return null;
    }

    return EixamTelRelayRxPacket(
      payload: List<int>.unmodifiable(bytes),
      relay: DeviceTelRelayRx(
        peerPayload: peerPayload,
        peerPosition: TrackingPosition(
          latitude: peerPacket.position.latitude,
          longitude: peerPacket.position.longitude,
          altitude: peerPacket.position.altitudeMeters.toDouble(),
          timestamp: receivedAt ?? DateTime.now(),
          source: DeliveryMode.mesh,
        ),
        rxSnr: rxSnr,
        rxRssi: rxRssi,
        selfPayload: selfPayload,
        selfPosition: TrackingPosition(
          latitude: selfPacket.position.latitude,
          longitude: selfPacket.position.longitude,
          altitude: selfPacket.position.altitudeMeters.toDouble(),
          timestamp: receivedAt ?? DateTime.now(),
          source: DeliveryMode.mesh,
        ),
        receivedAt: receivedAt,
      ),
    );
  }
}
