import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'eixam_tel_packet.dart';

class EixamTelRelayRxPacket {
  const EixamTelRelayRxPacket({
    required this.payload,
    required this.relay,
    required this.peerPacket,
    required this.selfPacket,
  });

  static const int opcode = 0xD2;
  static const int payloadLength = 27;

  final List<int> payload;
  final DeviceTelRelayRx relay;
  final EixamTelPacket peerPacket;
  final EixamTelPacket selfPacket;

  static EixamTelRelayRxPacket? tryParse(
    List<int> bytes, {
    DateTime? receivedAt,
  }) {
    if (bytes.length != payloadLength || bytes.first != opcode) {
      return null;
    }

    final peerPayload = List<int>.unmodifiable(bytes.sublist(1, 13));
    final peerPacket = EixamTelPacket.tryParse(peerPayload);
    if (peerPacket == null) {
      return null;
    }

    final rxSnr = bytes[13] >= 0x80 ? bytes[13] - 0x100 : bytes[13];
    final rxRssi = bytes[14] >= 0x80 ? bytes[14] - 0x100 : bytes[14];

    final selfPayload = List<int>.unmodifiable(bytes.sublist(15, 27));
    final selfPacket = EixamTelPacket.tryParse(selfPayload);
    if (selfPacket == null) {
      return null;
    }

    return EixamTelRelayRxPacket(
      payload: List<int>.unmodifiable(bytes),
      peerPacket: peerPacket,
      selfPacket: selfPacket,
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
