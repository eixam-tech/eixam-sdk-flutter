import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'activity_recording_ingestion_test.dart' show batch;
import 'recording_history_test_support.dart';
import 'recording_test_support.dart';

void main() {
  for (final scenario in [(1000, 500), (10000, 2000), (100000, 100)]) {
    final (count, recovered) = scenario;
    test(
      '$count live + $recovered middle D1 points through coordinator',
      () async {
        final h = RecordingHistoryHarness();
        await h.create();
        final f = h.f;
        try {
          final r = await f.start(device: tagA);
          final start = r.recordingStartedAt;
          final t = start.millisecondsSinceEpoch ~/ 1000;
          f.now = start.add(Duration(seconds: count * 2 + 10));
          final boundary = count ~/ 4;
          Future<void> append(int from, int until) async {
            for (var i = from; i < until; i += 24) {
              await f.controller.ingestLive(
                batch(
                  f,
                  List.generate(
                    until - i < 24 ? until - i : 24,
                    (n) => h.sample(t + (i + n) * 2, 1),
                  ),
                ),
              );
            }
          }

          await append(0, boundary + 1);
          await f.controller.inputDisconnected(tagA, false);
          final reconnect = start.add(
            Duration(seconds: (boundary + recovered) * 2),
          );
          final finish = f.now;
          f.now = reconnect;
          await f.controller.inputDisconnected(tagA, true);
          f.now = finish;
          await append(boundary + 1, count);
          await h.ready();
          final rss = ProcessInfo.currentRss;
          final watch = Stopwatch()..start();
          final recovery = f.controller.recoverActivityRecordingHistory(
            recordingId: r.recordingId,
          );
          await pumpEventQueue();
          await h.send(h.meta(recovered + 2));
          await h.send(h.chunk(t + boundary * 2));
          for (var i = 0; i < recovered; i++) {
            await h.send(h.chunk(t + boundary * 2 + i * 2 + 1, index: i + 1));
          }
          await h.send(
            h.chunk(t + (boundary + recovered) * 2, index: recovered + 1),
          );
          final insertion = watch.elapsedMicroseconds;
          await h.send(h.end(recovered + 2));
          final result = await recovery;
          final total = watch.elapsedMicroseconds;
          watch.reset();
          var points = 0;
          await for (final page in f.controller.readActivityRecordingRoute(
            recordingId: r.recordingId,
          )) {
            points += page.segments.fold(0, (n, s) => n + s.points.length);
            expect(page.routeRevision, result.routeRevision);
          }
          expect(points, count + recovered);
          expect(result.pointCount, count + recovered);
          expect(result.segmentCount, 1);
          expect(result.unresolvedGapCount, 0);
          expect(result.recordedDistanceMeters, 0);
          expect(result.routeQuality, ActivityRecordingRouteQuality.unknown);
          expect(
            result.routeChangedFrom,
            start.add(Duration(seconds: (boundary - 1) * 2)),
          );
          debugPrint(
            'AR2CA_PERF live=$count recovered=$recovered unit=us insertionWithDistance=$insertion '
            'reconcile=${total - insertion} total=$total paging=${watch.elapsedMicroseconds} '
            'rssDelta=${ProcessInfo.currentRss - rss} rss=${ProcessInfo.currentRss}',
          );
        } finally {
          await h.delete();
        }
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }
}
