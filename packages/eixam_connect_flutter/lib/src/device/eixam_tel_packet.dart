import 'eixam_ble_protocol.dart';
import 'eixam_position_data.dart';

class EixamTelPacket {
  const EixamTelPacket({
    required this.rawBytes,
    required this.rawHex,
    required this.nodeId,
    required this.position,
    required this.metaWord,
    required this.batteryLevel,
    required this.gpsQuality,
    required this.packetId,
    required this.speedBucket,
    required this.headingBucket,
  });

  final List<int> rawBytes;
  final String rawHex;
  final int nodeId;
  final EixamPositionData position;
  final int metaWord;
  final int batteryLevel;
  final int gpsQuality;
  final int packetId;
  final int speedBucket;
  final int headingBucket;

  static EixamTelPacket? tryParse(List<int> bytes) {
    if (bytes.length != EixamBleProtocol.telPacketLength) {
      return null;
    }

    final metaOffset = 10;
    return EixamTelPacket(
      rawBytes: List<int>.unmodifiable(bytes),
      rawHex: EixamBleProtocol.hex(bytes),
      nodeId: _readU32(bytes, 0),
      position: EixamPositionData.decode(bytes, offset: 4),
      metaWord: bytes[metaOffset] | (bytes[metaOffset + 1] << 8),
      batteryLevel: (bytes[metaOffset] >> 6) & 0x03,
      gpsQuality: (bytes[metaOffset] >> 4) & 0x03,
      packetId: bytes[metaOffset] & 0x0F,
      speedBucket: (bytes[metaOffset + 1] >> 4) & 0x0F,
      headingBucket: bytes[metaOffset + 1] & 0x0F,
    );
  }

  static int _readU32(List<int> bytes, int offset) {
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  }
}
