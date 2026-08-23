import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/eixam_position_backlog_packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final receivedAt = DateTime.utc(2026, 8, 23, 12);

  test('parses strict META, CHUNK, END, and ERROR packets', () {
    final meta = EixamPositionBacklogPacket.tryParse(
      _meta(sessionId: 7, total: 2, start: 4, end: 5),
      receivedAt: receivedAt,
    ) as EixamPositionBacklogMeta;
    expect(meta.totalEvents, 2);
    expect(meta.startIndex, 4);

    final chunk = EixamPositionBacklogPacket.tryParse(
      _chunk(sessionId: 7, index: 4, timeUnix: 1787486400),
      receivedAt: receivedAt,
    ) as EixamPositionBacklogChunk;
    expect(chunk.logicalIndex, 4);
    expect(chunk.batch.samples.single.sampledAt,
        DateTime.fromMillisecondsSinceEpoch(1787486400000, isUtc: true));
    expect(chunk.batch.source, SdkLocationSource.connectedDevice);

    final end = EixamPositionBacklogPacket.tryParse(
      _end(sessionId: 7, sent: 2, last: 5),
      receivedAt: receivedAt,
    ) as EixamPositionBacklogEnd;
    expect(end.sentEvents, 2);
    expect(end.lastIndex, 5);

    final error = EixamPositionBacklogPacket.tryParse(
      <int>[0xD1, 0x04, 7, 2, 9],
      receivedAt: receivedAt,
    ) as EixamPositionBacklogError;
    expect(error.code, 2);
    expect(error.detail, 9);
  });

  test('fails closed for malformed framing and model fields', () {
    final validMeta = _meta(sessionId: 7, total: 2, start: 4, end: 5);
    final validChunk = _chunk(
      sessionId: 7,
      index: 4,
      timeUnix: 1787486400,
    );
    for (final malformed in <List<int>>[
      validMeta.sublist(0, 13),
      <int>[...validMeta]..[0] = 0xD2,
      <int>[...validMeta]..[2] = 0,
      <int>[...validMeta]..[3] = 2,
      <int>[...validMeta]..[13] = 4,
      validChunk.sublist(0, 23),
      <int>[...validChunk]..[7] = 2,
      <int>[...validChunk]..setRange(8, 12, <int>[0, 0, 0, 0]),
      <int>[0xD1, 0x03, 7, 0, 0, 0, 0, 0, 0],
      <int>[0xD1, 0x04, 7, 0, 9],
    ]) {
      expect(
        EixamPositionBacklogPacket.tryParse(
          malformed,
          receivedAt: receivedAt,
        ),
        isNull,
      );
    }
  });

  test('same-second different wire records keep distinct opaque identities',
      () {
    final first = EixamPositionBacklogPacket.tryParse(
      _chunk(sessionId: 7, index: 0, timeUnix: 1787486400, packetId: 1),
      receivedAt: receivedAt,
    ) as EixamPositionBacklogChunk;
    final secondBytes =
        _chunk(sessionId: 7, index: 1, timeUnix: 1787486400, packetId: 1)
          ..[16] = 0x02;
    final second = EixamPositionBacklogPacket.tryParse(
      secondBytes,
      receivedAt: receivedAt,
    ) as EixamPositionBacklogChunk;

    expect(first.batch.samples.single.stableSampleKey,
        isNot(second.batch.samples.single.stableSampleKey));
  });
}

List<int> _meta({
  required int sessionId,
  required int total,
  required int start,
  required int end,
}) =>
    <int>[
      0xD1,
      0x01,
      sessionId,
      1,
      ..._u16(total),
      ..._u32(start),
      ..._u32(end),
    ];

List<int> _chunk({
  required int sessionId,
  required int index,
  required int timeUnix,
  int packetId = 1,
}) =>
    <int>[
      0xD1,
      0x02,
      sessionId,
      ..._u32(index),
      1,
      ..._u32(timeUnix),
      ..._wire(packetId),
    ];

List<int> _end({
  required int sessionId,
  required int sent,
  required int last,
}) =>
    <int>[0xD1, 0x03, sessionId, ..._u16(sent), ..._u32(last), 0];

List<int> _u16(int value) => <int>[value & 0xFF, (value >> 8) & 0xFF];
List<int> _u32(int value) => <int>[
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
    ];
List<int> _wire(int packetId) => <int>[
      0x78,
      0x56,
      0x34,
      0x12,
      0x01,
      0x02,
      0x03,
      0x04,
      0x05,
      0x06,
      0x80 | (packetId & 0x0F),
      0x25,
    ];
