import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'activity_recording_ingestion_test.dart' show batch, sample;
import 'recording_test_support.dart';

void main() {
  for (final paused in [false, true]) {
    test('WAL checkpoint/reuse with paused reader=$paused', () async {
      final f = await RecordingFixture.create();
      StreamSubscription<SdkActivityRoutePage>? reader;
      try {
        final r = await f.start(device: tagA);
        final start = r.recordingStartedAt;
        f.now = start.add(const Duration(seconds: 200));
        await f.controller.ingestLive(
          batch(f, [
            for (var i = 0; i < 3; i++)
              sample('p$i', start.add(Duration(seconds: i))),
          ]),
        );
        final db = await f.raw();
        try {
          await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
          if (paused) {
            final first = Completer<void>();
            reader = f.controller
                .readActivityRecordingRoute(
                  recordingId: r.recordingId,
                  pageSize: 1,
                )
                .listen((page) {
                  reader!.pause();
                  first.complete();
                });
            await first.future;
          }
          final writes = <int>[];
          for (var i = 3; i < 103; i++) {
            final watch = Stopwatch()..start();
            await f.controller.ingestLive(
              batch(f, [sample('p$i', start.add(Duration(seconds: i)))]),
            );
            writes.add(watch.elapsedMicroseconds);
          }
          final wal = File('${f.path}-wal');
          final before = await wal.length();
          final passive = (await db.rawQuery(
            'PRAGMA wal_checkpoint(PASSIVE)',
          )).single;
          expect(passive['busy'], 0);
          expect(
            passive['checkpointed'],
            passive['log'],
            reason: 'A paused consumer must not pin historical WAL frames.',
          );
          // A second write/checkpoint cycle must also reuse/checkpoint the WAL.
          await f.controller.ingestLive(
            batch(f, [sample('p103', start.add(const Duration(seconds: 103)))]),
          );
          final afterWrite = await wal.length();
          final second = (await db.rawQuery(
            'PRAGMA wal_checkpoint(PASSIVE)',
          )).single;
          expect(second['busy'], 0);
          expect(second['checkpointed'], second['log']);
          expect(f.store.activeTransactions, 0);
          if (paused) expect(reader!.isPaused, isTrue);
          writes.sort();
          debugPrint(
            'FIX1_WAL ${jsonEncode({'paused': paused, 'walBeforeCheckpointBytes': before, 'walAfterNextCommitBytes': afterWrite, 'checkpoint': passive, 'secondCheckpoint': second, 'writeMedianUs': writes[writes.length ~/ 2], 'writeMaxUs': writes.last})}',
          );
        } finally {
          await db.close();
        }
      } finally {
        await reader?.cancel();
        await f.delete();
      }
    });
  }
}
