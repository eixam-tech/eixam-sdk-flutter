import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'eixam_position_sample_identity.dart';
import 'eixam_tel_packet.dart';

sealed class EixamPositionBacklogPacket {
  const EixamPositionBacklogPacket(this.sessionId);

  static const int marker = 0xD1;
  final int sessionId;

  static EixamPositionBacklogPacket? tryParse(
    List<int> bytes, {
    required DateTime receivedAt,
  }) {
    if (bytes.length < 3 || bytes[0] != marker) return null;
    final sessionId = bytes[2];
    if (sessionId == 0) return null;
    return switch (bytes[1]) {
      0x01 => EixamPositionBacklogMeta.tryParse(bytes),
      0x02 => EixamPositionBacklogChunk.tryParse(
          bytes,
          receivedAt: receivedAt,
        ),
      0x03 => EixamPositionBacklogEnd.tryParse(bytes),
      0x04 => EixamPositionBacklogError.tryParse(bytes),
      _ => null,
    };
  }

  static int readU16(List<int> bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8);

  static int readU32(List<int> bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

final class EixamPositionBacklogMeta extends EixamPositionBacklogPacket {
  const EixamPositionBacklogMeta._({
    required int sessionId,
    required this.totalEvents,
    required this.startIndex,
    required this.endIndex,
  }) : super(sessionId);

  static const int protocolVersion = 1;
  final int totalEvents;
  final int startIndex;
  final int endIndex;

  static EixamPositionBacklogMeta? tryParse(List<int> bytes) {
    if (bytes.length != 14 ||
        bytes[0] != EixamPositionBacklogPacket.marker ||
        bytes[1] != 0x01 ||
        bytes[2] == 0 ||
        bytes[3] != protocolVersion) {
      return null;
    }
    final total = EixamPositionBacklogPacket.readU16(bytes, 4);
    final start = EixamPositionBacklogPacket.readU32(bytes, 6);
    final end = EixamPositionBacklogPacket.readU32(bytes, 10);
    if ((total == 0 && (start != 0 || end != 0)) ||
        (total > 0 && (end < start || end - start + 1 != total))) {
      return null;
    }
    return EixamPositionBacklogMeta._(
      sessionId: bytes[2],
      totalEvents: total,
      startIndex: start,
      endIndex: end,
    );
  }
}

final class EixamPositionBacklogChunk extends EixamPositionBacklogPacket {
  const EixamPositionBacklogChunk._({
    required int sessionId,
    required this.logicalIndex,
    required this.timeUnix,
    required this.wire12,
    required this.telPacket,
    required this.batch,
  }) : super(sessionId);

  final int logicalIndex;
  final int timeUnix;
  final List<int> wire12;
  final EixamTelPacket telPacket;
  final EixamDevicePositionBatch batch;

  static EixamPositionBacklogChunk? tryParse(
    List<int> bytes, {
    required DateTime receivedAt,
  }) {
    if (bytes.length != 24 ||
        bytes[0] != EixamPositionBacklogPacket.marker ||
        bytes[1] != 0x02 ||
        bytes[2] == 0 ||
        bytes[7] != 1) {
      return null;
    }
    final timeUnix = EixamPositionBacklogPacket.readU32(bytes, 8);
    // Persistent records may be old, but boot-relative/zero values are not UTC.
    if (timeUnix < 946684800) return null;
    final latestUsableUnix = receivedAt
            .toUtc()
            .add(const Duration(minutes: 10))
            .millisecondsSinceEpoch ~/
        Duration.millisecondsPerSecond;
    if (timeUnix > latestUsableUnix) return null;
    final wire = List<int>.unmodifiable(bytes.sublist(12, 24));
    final telPacket = EixamTelPacket.tryParse(wire);
    if (telPacket == null) return null;
    final sampledAt = DateTime.fromMillisecondsSinceEpoch(
      timeUnix * Duration.millisecondsPerSecond,
      isUtc: true,
    );
    final record = <int>[...bytes.sublist(8, 12), ...wire];
    final sample = EixamDevicePositionSample(
      latitude: telPacket.position.latitude,
      longitude: telPacket.position.longitude,
      altitudeMeters: telPacket.position.altitudeMeters.toDouble(),
      sampledAt: sampledAt,
      packetId: telPacket.packetId,
      source: SdkLocationSource.connectedDevice,
      stableSampleKey: EixamPositionSampleIdentity.liveRecord(record),
    );
    return EixamPositionBacklogChunk._(
      sessionId: bytes[2],
      logicalIndex: EixamPositionBacklogPacket.readU32(bytes, 3),
      timeUnix: timeUnix,
      wire12: wire,
      telPacket: telPacket,
      batch: EixamDevicePositionBatch(
        samples: <EixamDevicePositionSample>[sample],
        receivedAt: receivedAt.toUtc(),
        source: SdkLocationSource.connectedDevice,
        delivery: EixamDevicePositionDelivery.recovered,
      ),
    );
  }
}

final class EixamPositionBacklogEnd extends EixamPositionBacklogPacket {
  const EixamPositionBacklogEnd._({
    required int sessionId,
    required this.sentEvents,
    required this.lastIndex,
    required this.status,
  }) : super(sessionId);

  final int sentEvents;
  final int lastIndex;
  final int status;

  static EixamPositionBacklogEnd? tryParse(List<int> bytes) {
    if (bytes.length != 10 ||
        bytes[0] != EixamPositionBacklogPacket.marker ||
        bytes[1] != 0x03 ||
        bytes[2] == 0) {
      return null;
    }
    return EixamPositionBacklogEnd._(
      sessionId: bytes[2],
      sentEvents: EixamPositionBacklogPacket.readU16(bytes, 3),
      lastIndex: EixamPositionBacklogPacket.readU32(bytes, 5),
      status: bytes[9],
    );
  }
}

final class EixamPositionBacklogError extends EixamPositionBacklogPacket {
  const EixamPositionBacklogError._({
    required int sessionId,
    required this.code,
    required this.detail,
  }) : super(sessionId);

  final int code;
  final int detail;

  static EixamPositionBacklogError? tryParse(List<int> bytes) {
    if (bytes.length != 5 ||
        bytes[0] != EixamPositionBacklogPacket.marker ||
        bytes[1] != 0x04 ||
        bytes[2] == 0 ||
        bytes[3] == 0) {
      return null;
    }
    return EixamPositionBacklogError._(
      sessionId: bytes[2],
      code: bytes[3],
      detail: bytes[4],
    );
  }
}
