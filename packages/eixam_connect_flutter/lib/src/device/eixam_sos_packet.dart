import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'eixam_ble_protocol.dart';
import 'canonical_hardware_id.dart';
import 'eixam_position_data.dart';

enum EixamSosPacketFormat { minimal, delta, full }

class EixamSosPacket {
  const EixamSosPacket({
    required this.rawBytes,
    required this.rawHex,
    required this.format,
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
    this.deltaLatMeters,
    this.deltaLonMeters,
    this.position,
    this.remoteDeviceId,
  });

  final List<int> rawBytes;
  final String rawHex;
  final EixamSosPacketFormat format;
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
  final int? deltaLatMeters;
  final int? deltaLonMeters;
  final EixamPositionData? position;
  final String? remoteDeviceId;

  /// Bit 5 of the 12 B flags word. TEL speed nibble uses bits 5–4; SOS leaves
  /// them clear (`speedEst == 0`). Do not treat SOS `gpsQuality == 2` as TEL.
  bool get formatBitIsTelPosition => (flagsWord & 0x0020) != 0;

  bool get hasValidPosition {
    final decoded = position;
    if (!hasPosition || decoded == null) {
      return false;
    }
    return EixamGeoCoordinates.isValidFix(
      decoded.latitude,
      decoded.longitude,
    );
  }

  bool get isClear => format == EixamSosPacketFormat.minimal && sosType == 0;

  /// Active emergency, including 7 B `sosType = 3` without a fix (2.7.50).
  /// On TEL/BLE without hop metadata: `bit5 == 0 && sosType != 0`.
  bool get isActiveSos => isActiveOnChannel(EixamBleChannel.tel);

  /// SOS GATT 12 B is SOS even if bit 5 is set. Bit 5 only disambiguates TEL.
  bool isActiveOnChannel(EixamBleChannel channel) {
    if (sosType == 0) {
      return false;
    }
    if (format != EixamSosPacketFormat.full) {
      return true;
    }
    if (channel == EixamBleChannel.sos) {
      return true;
    }
    return !formatBitIsTelPosition;
  }

  TrackingPosition? trackingPositionAt(DateTime receivedAt) {
    final decoded = position;
    if (!hasValidPosition || decoded == null) {
      return null;
    }
    return TrackingPosition(
      latitude: decoded.latitude,
      longitude: decoded.longitude,
      altitude: decoded.altitudeMeters.toDouble(),
      timestamp: receivedAt,
      source: DeliveryMode.mesh,
    );
  }

  static int packFlags({
    required int sosType,
    int retryCount = 0,
    int relayCount = 0,
    int batteryLevel = 0,
    int gpsQuality = 0,
    int speedEstimate = 0,
    int packetId = 0,
  }) {
    return ((sosType & 0x03) << 14) |
        ((retryCount & 0x03) << 12) |
        ((relayCount & 0x03) << 10) |
        ((batteryLevel & 0x03) << 8) |
        ((gpsQuality & 0x03) << 6) |
        ((speedEstimate & 0x03) << 4) |
        (packetId & 0x0F);
  }

  static EixamSosPacket? tryParse(List<int> bytes) {
    final hasRemoteDeviceId =
        bytes.length == EixamBleProtocol.sosPacketLengthWithPosition + 6 ||
            bytes.length == EixamBleProtocol.sosPacketLengthDelta + 6 ||
            bytes.length == EixamBleProtocol.sosPacketLengthMinimal + 6;
    final packetLength = hasRemoteDeviceId ? bytes.length - 6 : bytes.length;
    final format = _formatForLength(packetLength);
    if (format == null) {
      return null;
    }

    final hasPosition = format == EixamSosPacketFormat.full;
    final flagsOffset = hasPosition ? 10 : 4;
    final flagsWord = bytes[flagsOffset] | (bytes[flagsOffset + 1] << 8);
    final sosType = (flagsWord >> 14) & 0x03;
    final decodedPosition =
        hasPosition ? EixamPositionData.decode(bytes, offset: 4) : null;
    final delta =
        format == EixamSosPacketFormat.delta ? _decodeDelta(bytes) : null;

    return EixamSosPacket(
      rawBytes: List<int>.unmodifiable(bytes),
      rawHex: EixamBleProtocol.hex(bytes),
      format: format,
      nodeId: _readU32(bytes, 0),
      flagsWord: flagsWord,
      sosType: sosType,
      retryCount: (flagsWord >> 12) & 0x03,
      relayCount: (flagsWord >> 10) & 0x03,
      batteryLevel: (flagsWord >> 8) & 0x03,
      gpsQuality: (flagsWord >> 6) & 0x03,
      speedEstimate: (flagsWord >> 4) & 0x03,
      packetId: flagsWord & 0x0F,
      hasPosition: hasPosition,
      sequence: hasPosition ? null : bytes[6],
      deltaLatMeters: delta?.$1,
      deltaLonMeters: delta?.$2,
      position: decodedPosition,
      remoteDeviceId: hasRemoteDeviceId
          ? _canonicalHardwareIdFrom(bytes.sublist(packetLength, bytes.length))
          : null,
    );
  }

  static EixamSosPacketFormat? _formatForLength(int packetLength) {
    if (packetLength == EixamBleProtocol.sosPacketLengthWithPosition) {
      return EixamSosPacketFormat.full;
    }
    if (packetLength == EixamBleProtocol.sosPacketLengthDelta) {
      return EixamSosPacketFormat.delta;
    }
    if (packetLength == EixamBleProtocol.sosPacketLengthMinimal) {
      return EixamSosPacketFormat.minimal;
    }
    return null;
  }

  static (int, int) _decodeDelta(List<int> bytes) {
    final packed = (bytes[7] << 16) | (bytes[8] << 8) | bytes[9];
    final qLat = _signExtend12((packed >> 12) & 0x0FFF);
    final qLon = _signExtend12(packed & 0x0FFF);
    return (qLat * 5, qLon * 5);
  }

  static int _signExtend12(int value) {
    return (value & 0x800) == 0 ? value : value - 0x1000;
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

  static int _readU32(List<int> bytes, int offset) {
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  }
}
