import 'eixam_ble_protocol.dart';

/// Rescue `STATUS_RESP` (`0x85`). Wire is **14 B** with `uint32` IDs.
/// Doc 16 §2 still describes 10 B; that is wrong.
class EixamRescueStatusRespPacket {
  const EixamRescueStatusRespPacket({
    required this.rawBytes,
    required this.rawHex,
    required this.rescuerNodeId,
    required this.victimNodeId,
    required this.state,
    required this.batteryLevel,
    required this.gpsQuality,
    required this.retryCount,
    required this.flags,
  });

  final List<int> rawBytes;
  final String rawHex;
  final int rescuerNodeId;
  final int victimNodeId;
  final int state;
  final int batteryLevel;
  final int gpsQuality;
  final int retryCount;
  final int flags;

  bool get relayPendingAck => (flags & 0x01) != 0;
  bool get inetAvailable => (flags & 0x02) != 0;

  static EixamRescueStatusRespPacket? tryParse(List<int> bytes) {
    if (bytes.length != EixamBleProtocol.rescueStatusRespLength) {
      return null;
    }
    if (bytes[8] != EixamBleProtocol.rescueCmdStatusResp) {
      return null;
    }
    return EixamRescueStatusRespPacket(
      rawBytes: List<int>.unmodifiable(bytes),
      rawHex: EixamBleProtocol.hex(bytes),
      rescuerNodeId: _readU32(bytes, 0),
      victimNodeId: _readU32(bytes, 4),
      state: bytes[9],
      batteryLevel: bytes[10],
      gpsQuality: bytes[11],
      retryCount: bytes[12],
      flags: bytes[13],
    );
  }

  static int _readU32(List<int> bytes, int offset) {
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  }
}
