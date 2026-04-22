import 'eixam_ble_protocol.dart';

class EixamClusterHeartbeatPacket {
  const EixamClusterHeartbeatPacket({
    required this.rawBytes,
    required this.rawHex,
    required this.nodeId,
    required this.score,
    required this.clusterId,
    required this.aggId,
    required this.memberCount,
    required this.aggSpreadingFactor,
  });

  final List<int> rawBytes;
  final String rawHex;
  final int nodeId;
  final int score;
  final int clusterId;
  final int aggId;
  final int memberCount;
  final int aggSpreadingFactor;

  static EixamClusterHeartbeatPacket? tryParse(List<int> bytes) {
    if (bytes.length != EixamBleProtocol.clusterHeartbeatPacketLength) {
      return null;
    }

    final packed = bytes[11];
    return EixamClusterHeartbeatPacket(
      rawBytes: List<int>.unmodifiable(bytes),
      rawHex: EixamBleProtocol.hex(bytes),
      nodeId: _readU32(bytes, 0),
      score: bytes[4],
      clusterId: _readU16(bytes, 5),
      aggId: _readU32(bytes, 7),
      memberCount: (packed >> 4) & 0x0F,
      aggSpreadingFactor: packed & 0x0F,
    );
  }

  static int _readU16(List<int> bytes, int offset) {
    return bytes[offset] | (bytes[offset + 1] << 8);
  }

  static int _readU32(List<int> bytes, int offset) {
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  }
}
