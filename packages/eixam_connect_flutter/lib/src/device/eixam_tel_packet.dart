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
    // Classic TEL packets are fixed-width 10-byte payloads.
    if (bytes.length != EixamBleProtocol.telPacketLength) {
      return null;
    }

    return EixamTelPacket(
      rawBytes: List<int>.unmodifiable(bytes),
      rawHex: EixamBleProtocol.hex(bytes),
      nodeId: bytes[0] | (bytes[1] << 8),
      position: EixamPositionData.decode(bytes, offset: 2),
      metaWord: bytes[8] | (bytes[9] << 8),
      batteryLevel: (bytes[8] >> 6) & 0x03,
      gpsQuality: (bytes[8] >> 4) & 0x03,
      packetId: bytes[8] & 0x0F,
      speedBucket: (bytes[9] >> 4) & 0x0F,
      headingBucket: bytes[9] & 0x0F,
    );
  }
}
