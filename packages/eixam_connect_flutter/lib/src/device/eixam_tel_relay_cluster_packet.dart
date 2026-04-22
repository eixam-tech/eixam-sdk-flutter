import 'eixam_tel_packet.dart';

class EixamTelRelayClusterPacket {
  const EixamTelRelayClusterPacket({
    required this.payload,
    required this.clusterId,
    required this.members,
  });

  static const int opcode = 0xC2;
  static const int _headerLength = 4;
  static const int _memberLength = 12;

  final List<int> payload;
  final int clusterId;
  final List<EixamTelRelayClusterMember> members;

  static EixamTelRelayClusterPacket? tryParse(List<int> bytes) {
    if (bytes.length < _headerLength || bytes.first != opcode) {
      return null;
    }

    final memberCount = bytes[3];
    if (memberCount <= 0) {
      return null;
    }

    final expectedLength = _headerLength + (memberCount * _memberLength);
    if (bytes.length != expectedLength) {
      return null;
    }

    final members = <EixamTelRelayClusterMember>[];
    var cursor = _headerLength;
    for (var index = 0; index < memberCount; index++) {
      final packet = EixamTelPacket.tryParse(
          bytes.sublist(cursor, cursor + _memberLength));
      if (packet == null) {
        return null;
      }
      members.add(
        EixamTelRelayClusterMember(
          packet: packet,
        ),
      );
      cursor += _memberLength;
    }

    return EixamTelRelayClusterPacket(
      payload: List<int>.unmodifiable(bytes),
      clusterId: bytes[1] | (bytes[2] << 8),
      members: List<EixamTelRelayClusterMember>.unmodifiable(members),
    );
  }
}

class EixamTelRelayClusterMember {
  const EixamTelRelayClusterMember({
    required this.packet,
  });

  final EixamTelPacket packet;
}
