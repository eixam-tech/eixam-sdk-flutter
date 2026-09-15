import 'dart:convert';
import 'dart:typed_data';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'eixam_ble_protocol.dart';

class EixamNearbyTextPacket {
  const EixamNearbyTextPacket({
    required this.fromNodeId,
    required this.destNodeId,
    required this.packetId,
    required this.groupId,
    required this.pkiEncrypted,
    required this.text,
    required this.payload,
  });

  final int fromNodeId;
  final int destNodeId;
  final int packetId;
  final int groupId;
  final bool pkiEncrypted;
  final String text;
  final List<int> payload;

  static EixamNearbyTextPacket? tryParse(List<int> bytes) {
    if (bytes.length < EixamBleProtocol.nearbyTextRxHeaderLength ||
        bytes.first != EixamBleProtocol.nearbyTextRxOpcode ||
        EixamBleProtocol.isReservedSosOrTelNotifyLength(bytes.length)) {
      return null;
    }
    final utf8Bytes = _stripLengthPad(
      bytes.sublist(EixamBleProtocol.nearbyTextRxHeaderLength),
    );
    if (utf8Bytes.isEmpty ||
        utf8Bytes.length > EixamBleProtocol.nearbyTextRxPayloadMaxBytes) {
      return null;
    }
    try {
      final text = utf8.decode(utf8Bytes);
      return EixamNearbyTextPacket(
        fromNodeId: _u32le(bytes, 1),
        destNodeId: _u32le(bytes, 5),
        packetId: _u32le(bytes, 9),
        groupId: _u64le(bytes, 13),
        pkiEncrypted: (bytes[21] & EixamBleProtocol.nearbyTextRxFlagPki) != 0,
        text: text,
        payload: List<int>.unmodifiable(bytes),
      );
    } on FormatException {
      return null;
    }
  }
}

class EixamNearbyTextTxStatusPacket {
  const EixamNearbyTextTxStatusPacket({
    required this.packetId,
    required this.status,
    required this.payload,
  });

  final int packetId;
  final NearbyTextTxStatus status;
  final List<int> payload;

  static EixamNearbyTextTxStatusPacket? tryParse(List<int> bytes) {
    if (bytes.length != EixamBleProtocol.nearbyTextTxStatusLength ||
        bytes.first != EixamBleProtocol.nearbyTextTxStatusOpcode) {
      return null;
    }
    final status = NearbyTextTxStatus.fromWire(bytes[5]);
    if (status == null) {
      return null;
    }
    return EixamNearbyTextTxStatusPacket(
      packetId: _u32le(bytes, 1),
      status: status,
      payload: List<int>.unmodifiable(bytes),
    );
  }
}

class EixamNearbyOwnerNamePacket {
  const EixamNearbyOwnerNamePacket({
    required this.nodeId,
    required this.name,
    required this.payload,
  });

  final int nodeId;
  final String name;
  final List<int> payload;

  static EixamNearbyOwnerNamePacket? tryParse(List<int> bytes) {
    if (bytes.length <= EixamBleProtocol.nearbyOwnerNameRxHeaderLength ||
        bytes.first != EixamBleProtocol.nearbyOwnerNameRxOpcode) {
      return null;
    }
    final utf8Bytes = bytes.sublist(
      EixamBleProtocol.nearbyOwnerNameRxHeaderLength,
    );
    if (utf8Bytes.isEmpty ||
        utf8Bytes.length > EixamBleProtocol.nearbyOwnerNameMaxBytes) {
      return null;
    }
    try {
      final name = utf8.decode(utf8Bytes).trim();
      if (name.isEmpty) {
        return null;
      }
      return EixamNearbyOwnerNamePacket(
        nodeId: _u32le(bytes, 1),
        name: name,
        payload: List<int>.unmodifiable(bytes),
      );
    } on FormatException {
      return null;
    }
  }
}

class EixamNearbyTextFramer {
  static List<List<int>> txFragments({
    required int packetId,
    required List<int> utf8Bytes,
    int destNodeId = EixamBleProtocol.nearbyTextBroadcastDest,
    int groupId = 0,
  }) {
    if (packetId == 0) {
      throw ArgumentError('packetId must be non-zero');
    }
    final blob = Uint8List(
      EixamBleProtocol.nearbyTextTxHeaderLength + utf8Bytes.length,
    );
    _writeU32le(blob, 0, destNodeId);
    _writeU32le(blob, 4, packetId);
    _writeU64le(blob, 8, groupId);
    blob.setRange(
      EixamBleProtocol.nearbyTextTxHeaderLength,
      blob.length,
      utf8Bytes,
    );
    return _fragment(opcode: EixamBleProtocol.nearbyTextTxOpcode, blob: blob);
  }

  static List<List<int>> groupFragments({
    required int action,
    required int groupId,
    List<int> psk = const <int>[],
  }) {
    if (groupId == 0) {
      throw ArgumentError('groupId must be non-zero');
    }
    if (action != EixamBleProtocol.nearbyTextGroupSet &&
        action != EixamBleProtocol.nearbyTextGroupSetReplace &&
        action != EixamBleProtocol.nearbyTextGroupClear) {
      throw ArgumentError('invalid group action');
    }
    if ((action == EixamBleProtocol.nearbyTextGroupSet ||
            action == EixamBleProtocol.nearbyTextGroupSetReplace) &&
        psk.length != 32) {
      throw ArgumentError('group PSK must be 32 bytes');
    }
    final blob = Uint8List(EixamBleProtocol.nearbyTextGroupBlobLength);
    blob[0] = action;
    _writeU64le(blob, 1, groupId);
    if (psk.isNotEmpty) {
      blob.setRange(9, 9 + psk.length, psk);
    }
    return _fragment(
      opcode: EixamBleProtocol.nearbyTextGroupOpcode,
      blob: blob,
    );
  }

  static List<List<int>> ownerNameFragments(List<int> utf8Bytes) {
    if (utf8Bytes.isEmpty ||
        utf8Bytes.length > EixamBleProtocol.nearbyOwnerNameMaxBytes) {
      throw ArgumentError('owner name must be 1–39 UTF-8 bytes');
    }
    return _fragment(
      opcode: EixamBleProtocol.nearbyOwnerNameOpcode,
      blob: Uint8List.fromList(utf8Bytes),
    );
  }

  static List<List<int>> _fragment({
    required int opcode,
    required Uint8List blob,
  }) {
    final frames = <List<int>>[];
    var offset = 0;
    while (offset < blob.length) {
      final end =
          offset + EixamBleProtocol.telAggregateFragmentMaxPayloadLength;
      final chunk = blob.sublist(offset, end > blob.length ? blob.length : end);
      frames.add(<int>[
        opcode,
        blob.length & 0xFF,
        (blob.length >> 8) & 0xFF,
        offset & 0xFF,
        (offset >> 8) & 0xFF,
        ...chunk,
      ]);
      offset += chunk.length;
    }
    return frames;
  }
}

void _writeU32le(Uint8List bytes, int offset, int value) {
  final v = value.toUnsigned(32);
  bytes[offset] = v & 0xFF;
  bytes[offset + 1] = (v >> 8) & 0xFF;
  bytes[offset + 2] = (v >> 16) & 0xFF;
  bytes[offset + 3] = (v >> 24) & 0xFF;
}

void _writeU64le(Uint8List bytes, int offset, int value) {
  _writeU32le(bytes, offset, value);
  _writeU32le(bytes, offset + 4, value >> 32);
}

int _u32le(List<int> bytes, int offset) {
  return (bytes[offset] |
          (bytes[offset + 1] << 8) |
          (bytes[offset + 2] << 16) |
          (bytes[offset + 3] << 24)) &
      0xFFFFFFFF;
}

int _u64le(List<int> bytes, int offset) {
  final lo = _u32le(bytes, offset);
  final hi = _u32le(bytes, offset + 4);
  return (hi << 32) | lo;
}

List<int> _stripLengthPad(List<int> utf8Bytes) {
  var end = utf8Bytes.length;
  while (end > 0 &&
      utf8Bytes[end - 1] == EixamBleProtocol.nearbyTextLengthPad) {
    end--;
  }
  return utf8Bytes.sublist(0, end);
}
