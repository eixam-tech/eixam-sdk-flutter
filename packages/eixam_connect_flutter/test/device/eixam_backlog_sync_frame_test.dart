import 'package:eixam_connect_flutter/src/device/eixam_backlog_sync_frame.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EixamBacklogSyncFrame', () {
    test('parses SYNC_META frames', () {
      final frame = EixamBacklogSyncFrame.tryParse(
        const <int>[
          0xD1,
          0x01,
          0x07,
          0x05,
          0x00,
          0x10,
          0x00,
          0x00,
          0x00,
          0x15,
          0x00,
          0x00,
          0x00,
        ],
      ) as EixamBacklogSyncMetaFrame?;

      expect(frame, isNotNull);
      expect(frame!.sessionId, 0x07);
      expect(frame.totalEvents, 5);
      expect(frame.startOffset, 16);
      expect(frame.endOffset, 21);
    });

    test('parses SYNC_CHUNK frames with TEL records', () {
      final frame = EixamBacklogSyncFrame.tryParse(
        const <int>[
          0xD1,
          0x02,
          0x07,
          0x10,
          0x00,
          0x00,
          0x00,
          0x02,
          0xA0,
          0xBB,
          0xF0,
          0x65,
          0xA8,
          0x1A,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x01,
          0x21,
          0xA1,
          0xBB,
          0xF0,
          0x65,
          0xB0,
          0x1B,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x01,
          0x21,
        ],
      ) as EixamBacklogSyncChunkFrame?;

      expect(frame, isNotNull);
      expect(frame!.chunkOffset, 16);
      expect(frame.records, hasLength(2));
      expect(frame.records.first.timeUnix, 0x65F0BBA0);
      expect(frame.records.first.telPacket.nodeId, 0x1AA8);
      expect(frame.records.last.telPacket.nodeId, 0x1BB0);
    });

    test('parses SYNC_END and SYNC_ERROR frames', () {
      final end = EixamBacklogSyncFrame.tryParse(
        const <int>[0xD1, 0x03, 0x07, 0x05, 0x00, 0x15, 0x00, 0x00, 0x00, 0x00],
      ) as EixamBacklogSyncEndFrame?;
      final error = EixamBacklogSyncFrame.tryParse(
        const <int>[0xD1, 0x04, 0x07, 0x09, 0x02],
      ) as EixamBacklogSyncErrorFrame?;

      expect(end, isNotNull);
      expect(end!.sentEvents, 5);
      expect(end.lastOffset, 21);
      expect(end.status, 0);
      expect(error, isNotNull);
      expect(error!.code, 9);
      expect(error.detail, 2);
    });
  });
}
