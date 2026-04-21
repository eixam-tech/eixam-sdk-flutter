import 'canonical_hardware_id.dart';
import 'eixam_tel_packet.dart';

class EixamTelRelayClusterPacket {
  const EixamTelRelayClusterPacket({
    required this.payload,
    required this.members,
  });

  static const int opcode = 0xC2;
  static const int _memberLength = 16;

  final List<int> payload;
  final List<EixamTelRelayClusterMember> members;

  static EixamTelRelayClusterPacket? tryParse(List<int> bytes) {
    if (bytes.length < 2 || bytes.first != opcode) {
      return null;
    }

    final memberCount = bytes[1];
    if (memberCount <= 0) {
      return null;
    }

    final expectedLength = 2 + (memberCount * _memberLength);
    if (bytes.length != expectedLength) {
      return null;
    }

    final members = <EixamTelRelayClusterMember>[];
    var cursor = 2;
    for (var index = 0; index < memberCount; index++) {
      final remoteDeviceId = _canonicalHardwareIdFrom(
        bytes.sublist(cursor, cursor + 6),
      );
      final packet = EixamTelPacket.tryParse(
        bytes.sublist(cursor + 6, cursor + _memberLength),
      );
      if (remoteDeviceId == null || packet == null) {
        return null;
      }
      members.add(
        EixamTelRelayClusterMember(
          remoteDeviceId: remoteDeviceId,
          packet: packet,
        ),
      );
      cursor += _memberLength;
    }

    return EixamTelRelayClusterPacket(
      payload: List<int>.unmodifiable(bytes),
      members: List<EixamTelRelayClusterMember>.unmodifiable(members),
    );
  }

  static String? _canonicalHardwareIdFrom(List<int> bytes) {
    if (bytes.length != 6) {
      return null;
    }
    final candidate = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(':');
    return normalizeCanonicalHardwareId(candidate);
  }
}

class EixamTelRelayClusterMember {
  const EixamTelRelayClusterMember({
    required this.remoteDeviceId,
    required this.packet,
  });

  final String remoteDeviceId;
  final EixamTelPacket packet;
}
