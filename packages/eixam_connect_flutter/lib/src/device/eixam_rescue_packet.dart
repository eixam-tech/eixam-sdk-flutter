import 'eixam_ble_protocol.dart';

/// Rescue command header on port 261. Wire is **9 B**, `uint32` LE IDs, no
/// `param`. Doc 16 §2 still describes a 6 B layout; that is wrong.
class EixamRescuePacket {
  const EixamRescuePacket({
    required this.rawBytes,
    required this.rawHex,
    required this.targetNodeId,
    required this.fromNodeId,
    required this.command,
  });

  final List<int> rawBytes;
  final String rawHex;
  final int targetNodeId;
  final int fromNodeId;
  final int command;

  bool get isAckSos => command == EixamBleProtocol.rescueCmdAckSos;

  static EixamRescuePacket? tryParse(List<int> bytes) {
    if (bytes.length != EixamBleProtocol.rescueHeaderLength) {
      return null;
    }
    final command = bytes[8];
    if (command == EixamBleProtocol.rescueCmdStatusResp) {
      return null;
    }
    return EixamRescuePacket(
      rawBytes: List<int>.unmodifiable(bytes),
      rawHex: EixamBleProtocol.hex(bytes),
      targetNodeId: _readU32(bytes, 0),
      fromNodeId: _readU32(bytes, 4),
      command: command,
    );
  }

  static List<int> encode({
    required int targetNodeId,
    required int fromNodeId,
    required int command,
  }) {
    return <int>[
      targetNodeId & 0xFF,
      (targetNodeId >> 8) & 0xFF,
      (targetNodeId >> 16) & 0xFF,
      (targetNodeId >> 24) & 0xFF,
      fromNodeId & 0xFF,
      (fromNodeId >> 8) & 0xFF,
      (fromNodeId >> 16) & 0xFF,
      (fromNodeId >> 24) & 0xFF,
      command & 0xFF,
    ];
  }

  static int _readU32(List<int> bytes, int offset) {
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  }
}
