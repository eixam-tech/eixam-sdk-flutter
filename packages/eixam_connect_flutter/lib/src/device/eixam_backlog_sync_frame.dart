import 'eixam_ble_protocol.dart';
import 'eixam_tel_packet.dart';

enum EixamBacklogSyncMessageType {
  meta(0x01),
  chunk(0x02),
  end(0x03),
  error(0x04);

  const EixamBacklogSyncMessageType(this.code);

  final int code;

  static EixamBacklogSyncMessageType? fromCode(int code) {
    for (final value in values) {
      if (value.code == code) {
        return value;
      }
    }
    return null;
  }
}

abstract class EixamBacklogSyncFrame {
  const EixamBacklogSyncFrame({
    required this.messageType,
    required this.sessionId,
    required this.payload,
  });

  final EixamBacklogSyncMessageType messageType;
  final int sessionId;
  final List<int> payload;

  static EixamBacklogSyncFrame? tryParse(List<int> bytes) {
    if (bytes.length < 3 || bytes.first != EixamBleProtocol.backlogSyncOpcode) {
      return null;
    }
    final messageType = EixamBacklogSyncMessageType.fromCode(bytes[1]);
    if (messageType == null) {
      return null;
    }
    switch (messageType) {
      case EixamBacklogSyncMessageType.meta:
        return EixamBacklogSyncMetaFrame.tryParse(bytes);
      case EixamBacklogSyncMessageType.chunk:
        return EixamBacklogSyncChunkFrame.tryParse(bytes);
      case EixamBacklogSyncMessageType.end:
        return EixamBacklogSyncEndFrame.tryParse(bytes);
      case EixamBacklogSyncMessageType.error:
        return EixamBacklogSyncErrorFrame.tryParse(bytes);
    }
  }
}

class EixamBacklogSyncMetaFrame extends EixamBacklogSyncFrame {
  const EixamBacklogSyncMetaFrame({
    required super.sessionId,
    required super.payload,
    required this.totalEvents,
    required this.startOffset,
    required this.endOffset,
  }) : super(messageType: EixamBacklogSyncMessageType.meta);

  final int totalEvents;
  final int startOffset;
  final int endOffset;

  static EixamBacklogSyncMetaFrame? tryParse(List<int> bytes) {
    if (bytes.length != 13 ||
        bytes.first != EixamBleProtocol.backlogSyncOpcode ||
        bytes[1] != EixamBacklogSyncMessageType.meta.code) {
      return null;
    }
    return EixamBacklogSyncMetaFrame(
      sessionId: bytes[2],
      payload: List<int>.unmodifiable(bytes),
      totalEvents: _readU16(bytes, 3),
      startOffset: _readU32(bytes, 5),
      endOffset: _readU32(bytes, 9),
    );
  }
}

class EixamBacklogSyncRecord {
  const EixamBacklogSyncRecord({
    required this.timeUnix,
    required this.wirePayload,
    required this.telPacket,
  });

  final int timeUnix;
  final List<int> wirePayload;
  final EixamTelPacket telPacket;
}

class EixamBacklogSyncChunkFrame extends EixamBacklogSyncFrame {
  const EixamBacklogSyncChunkFrame({
    required super.sessionId,
    required super.payload,
    required this.chunkOffset,
    required this.records,
  }) : super(messageType: EixamBacklogSyncMessageType.chunk);

  final int chunkOffset;
  final List<EixamBacklogSyncRecord> records;

  static EixamBacklogSyncChunkFrame? tryParse(List<int> bytes) {
    if (bytes.length < 8 ||
        bytes.first != EixamBleProtocol.backlogSyncOpcode ||
        bytes[1] != EixamBacklogSyncMessageType.chunk.code) {
      return null;
    }
    final count = bytes[7];
    final expectedLength =
        8 + (count * EixamBleProtocol.backlogSyncRecordLength);
    if (bytes.length != expectedLength) {
      return null;
    }
    final records = <EixamBacklogSyncRecord>[];
    var cursor = 8;
    for (var i = 0; i < count; i++) {
      final timeUnix = _readU32(bytes, cursor);
      final wirePayload =
          List<int>.unmodifiable(bytes.sublist(cursor + 4, cursor + 14));
      final telPacket = EixamTelPacket.tryParse(wirePayload);
      if (telPacket == null) {
        return null;
      }
      records.add(
        EixamBacklogSyncRecord(
          timeUnix: timeUnix,
          wirePayload: wirePayload,
          telPacket: telPacket,
        ),
      );
      cursor += EixamBleProtocol.backlogSyncRecordLength;
    }
    return EixamBacklogSyncChunkFrame(
      sessionId: bytes[2],
      payload: List<int>.unmodifiable(bytes),
      chunkOffset: _readU32(bytes, 3),
      records: List<EixamBacklogSyncRecord>.unmodifiable(records),
    );
  }
}

class EixamBacklogSyncEndFrame extends EixamBacklogSyncFrame {
  const EixamBacklogSyncEndFrame({
    required super.sessionId,
    required super.payload,
    required this.sentEvents,
    required this.lastOffset,
    required this.status,
  }) : super(messageType: EixamBacklogSyncMessageType.end);

  final int sentEvents;
  final int lastOffset;
  final int status;

  static EixamBacklogSyncEndFrame? tryParse(List<int> bytes) {
    if (bytes.length != 10 ||
        bytes.first != EixamBleProtocol.backlogSyncOpcode ||
        bytes[1] != EixamBacklogSyncMessageType.end.code) {
      return null;
    }
    return EixamBacklogSyncEndFrame(
      sessionId: bytes[2],
      payload: List<int>.unmodifiable(bytes),
      sentEvents: _readU16(bytes, 3),
      lastOffset: _readU32(bytes, 5),
      status: bytes[9],
    );
  }
}

class EixamBacklogSyncErrorFrame extends EixamBacklogSyncFrame {
  const EixamBacklogSyncErrorFrame({
    required super.sessionId,
    required super.payload,
    required this.code,
    required this.detail,
  }) : super(messageType: EixamBacklogSyncMessageType.error);

  final int code;
  final int detail;

  static EixamBacklogSyncErrorFrame? tryParse(List<int> bytes) {
    if (bytes.length != 5 ||
        bytes.first != EixamBleProtocol.backlogSyncOpcode ||
        bytes[1] != EixamBacklogSyncMessageType.error.code) {
      return null;
    }
    return EixamBacklogSyncErrorFrame(
      sessionId: bytes[2],
      payload: List<int>.unmodifiable(bytes),
      code: bytes[3],
      detail: bytes[4],
    );
  }
}

int _readU16(List<int> bytes, int offset) {
  return bytes[offset] | (bytes[offset + 1] << 8);
}

int _readU32(List<int> bytes, int offset) {
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}
