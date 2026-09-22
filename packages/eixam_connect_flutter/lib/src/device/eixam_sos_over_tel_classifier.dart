import 'eixam_ble_protocol.dart';
import 'eixam_sos_packet.dart';

enum EixamSosOverTelKind { modernSos, tel, malformed }

/// Canonical discriminator for the 12-byte port-258/EA01 collision.
///
/// Firmware `isSosOverTel()` first rejects the TEL position marker (bit 5 of
/// the overlapping flags/meta word) and then accepts the current wire marker
/// `sosType == 3`. Legacy SOS needs mesh `hop_start` evidence, which BLE and
/// D2 do not carry, so legacy-looking 12-byte payloads fail closed to TEL.
class EixamSosOverTelClassification {
  const EixamSosOverTelClassification({
    required this.kind,
    required this.reason,
    this.sosPacket,
  });

  final EixamSosOverTelKind kind;
  final String reason;
  final EixamSosPacket? sosPacket;

  int? get parsedSosType => sosPacket?.sosType;
  int? get packetId => sosPacket?.packetId;
  int? get originatorNodeId => sosPacket?.nodeId;
  bool get isModernSos => kind == EixamSosOverTelKind.modernSos;
}

class EixamSosOverTelClassifier {
  const EixamSosOverTelClassifier();

  EixamSosOverTelClassification classify(List<int> payload) {
    if (payload.length != EixamBleProtocol.telPacketLength) {
      return const EixamSosOverTelClassification(
        kind: EixamSosOverTelKind.malformed,
        reason: 'invalid_12_byte_length',
      );
    }
    if (payload.any((byte) => byte < 0 || byte > 0xFF)) {
      return const EixamSosOverTelClassification(
        kind: EixamSosOverTelKind.malformed,
        reason: 'invalid_byte_domain',
      );
    }

    final packet = EixamSosPacket.tryParse(payload);
    if (packet == null || packet.format != EixamSosPacketFormat.full) {
      return const EixamSosOverTelClassification(
        kind: EixamSosOverTelKind.malformed,
        reason: 'invalid_full_sos_layout',
      );
    }
    if (packet.formatBitIsTelPosition) {
      return EixamSosOverTelClassification(
        kind: EixamSosOverTelKind.tel,
        reason: 'tel_position_format_bit_set',
        sosPacket: packet,
      );
    }
    if (packet.sosType == 3) {
      return EixamSosOverTelClassification(
        kind: EixamSosOverTelKind.modernSos,
        reason: 'modern_sos_type_3',
        sosPacket: packet,
      );
    }
    return EixamSosOverTelClassification(
      kind: EixamSosOverTelKind.tel,
      reason: 'legacy_or_non_sos_without_hop_proof',
      sosPacket: packet,
    );
  }
}
