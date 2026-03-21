import 'eixam_ble_protocol.dart';
import 'eixam_position_data.dart';

class EixamSosPacket {
  const EixamSosPacket({
    required this.rawBytes,
    required this.rawHex,
    required this.nodeId,
    required this.flagsWord,
    required this.sosType,
    required this.retryCount,
    required this.relayCount,
    required this.batteryLevel,
    required this.gpsQuality,
    required this.speedEstimate,
    required this.packetId,
    required this.hasPosition,
    this.sequence,
    this.position,
  });

  final List<int> rawBytes;
  final String rawHex;
  final int nodeId;
  final int flagsWord;
  final int sosType;
  final int retryCount;
  final int relayCount;
  final int batteryLevel;
  final int gpsQuality;
  final int speedEstimate;
  final int packetId;
  final bool hasPosition;
  final int? sequence;
  final EixamPositionData? position;

  static EixamSosPacket? tryParse(List<int> bytes) {
    if (bytes.length != EixamBleProtocol.sosPacketLengthWithPosition &&
        bytes.length != EixamBleProtocol.sosPacketLengthMinimal) {
      return null;
    }

    final hasPosition =
        bytes.length == EixamBleProtocol.sosPacketLengthWithPosition;
    final flagsOffset = hasPosition ? 8 : 2;
    final flagsWord = bytes[flagsOffset] | (bytes[flagsOffset + 1] << 8);

    return EixamSosPacket(
      rawBytes: List<int>.unmodifiable(bytes),
      rawHex: EixamBleProtocol.hex(bytes),
      nodeId: bytes[0] | (bytes[1] << 8),
      flagsWord: flagsWord,
      sosType: (flagsWord >> 14) & 0x03,
      retryCount: (flagsWord >> 12) & 0x03,
      relayCount: (flagsWord >> 10) & 0x03,
      batteryLevel: (flagsWord >> 8) & 0x03,
      gpsQuality: (flagsWord >> 6) & 0x03,
      speedEstimate: (flagsWord >> 4) & 0x03,
      packetId: flagsWord & 0x0F,
      hasPosition: hasPosition,
      sequence: hasPosition ? null : bytes[4],
      position: hasPosition ? EixamPositionData.decode(bytes, offset: 2) : null,
    );
  }
}
