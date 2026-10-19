import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'activity_recording_ingestion_test.dart' show sample, batch;
import 'recording_test_support.dart';

/// Host SQLite evidence, not a mobile SLA or a product retention ceiling.
void main() {
  for (final count in [1000, 10000, 100000]) {
    test(
      '$count TAG points: live persistence and route read benchmark',
      () async {
        var f = await RecordingFixture.create();
        final rss = ProcessInfo.currentRss;
        Future<int> measure(Future<void> Function() action) async {
          final watch = Stopwatch()..start();
          await action();
          return watch.elapsedMicroseconds;
        }

        try {
          final r = await f.start(device: tagA);
          final start = r.recordingStartedAt;
          f.now = start.add(Duration(seconds: count + 10));
          EixamDevicePositionSample point(int i) => sample(
            'p${i.toString().padLeft(8, '0')}',
            start.add(Duration(seconds: i)),
            latitude: 41 + i / 10000000,
            longitude: 2 + i / 10000000,
          );
          final insert = await measure(() async {
            for (var i = 0; i < count; i += 24) {
              final size = count - i < 24 ? count - i : 24;
              await f.controller.ingestLive(
                batch(f, List.generate(size, (offset) => point(i + offset))),
              );
            }
          });
          final summary = await measure(() async {
            expect(
              (await f.controller.getActiveActivityRecording())!.pointCount,
              count,
            );
          });
          final pages = await measure(() async {
            var total = 0;
            await for (final page in f.controller.readActivityRecordingRoute(
              recordingId: r.recordingId,
            )) {
              total += page.segments.fold<int>(
                0,
                (sum, s) => sum + s.points.length,
              );
            }
            expect(total, count);
          });
          final append = await measure(
            () => f.controller.ingestLive(batch(f, [point(count)])),
          );
          final middle = start.add(
            Duration(seconds: count ~/ 2, microseconds: 1),
          );
          final outOfOrder = await measure(
            () => f.controller.ingestLive(
              batch(f, [
                sample('middle', middle, latitude: 41.01, longitude: 2.01),
              ]),
            ),
          );
          final duplicate = await measure(
            () => f.controller.ingestLive(
              batch(f, List.generate(24, (_) => point(0))),
            ),
          );
          final directory = f.directory;
          final sessions = f.sessionStore;
          await f.dispose();
          f = await RecordingFixture.create(
            directory: directory,
            sessionStore: sessions,
          );
          f.now = start.add(Duration(seconds: count + 10));
          final restore = await measure(() async {
            final restored = await f.controller.getActiveActivityRecording();
            expect(restored!.pointCount, count + 2);
            expect(restored.recordedDistanceMeters, isNotNull);
          });
          debugPrint(
            'AR2B_PERF points=$count unit=us ingest=$insert summary=$summary '
            'paging=$pages append=$append outOfOrder=$outOfOrder duplicate=$duplicate restore=$restore '
            'rssDelta=${ProcessInfo.currentRss - rss} rss=${ProcessInfo.currentRss}',
          );
        } finally {
          await f.delete();
        }
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }
}
