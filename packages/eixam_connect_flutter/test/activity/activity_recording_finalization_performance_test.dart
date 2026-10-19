import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'activity_recording_ingestion_test.dart' show sample, batch;
import 'recording_history_test_support.dart';
import 'recording_test_support.dart';

/// Host SQLite timings; neither a mobile SLA nor a retention limit.
void main() {
  for (final scenario in [
    'empty',
    'connected',
    'gap',
    'partial',
    'disconnected',
    '10000',
    '100000',
  ]) {
    test('finish benchmark $scenario', () async {
      final h = RecordingHistoryHarness();
      await h.create();
      final f = h.f;
      try {
        final r = await f.start(device: tagA);
        final count = int.tryParse(scenario) ?? (scenario == 'empty' ? 0 : 2);
        final start = r.recordingStartedAt;
        final t = start.millisecondsSinceEpoch ~/ 1000;
        f.now = start.add(Duration(seconds: count + 10));
        for (var i = 0; i < count; i += 24) {
          await f.controller.ingestLive(
            batch(
              f,
              List.generate(
                count - i < 24 ? count - i : 24,
                (n) => count == 2
                    ? h.sample(t + i + n, i + n + 1)
                    : sample(
                        'p${(i + n).toString().padLeft(8, '0')}',
                        start.add(Duration(seconds: i + n)),
                        latitude: 41 + (i + n) / 10000000,
                        longitude: 2,
                      ),
              ),
            ),
          );
        }
        final hasGap =
            scenario == 'gap' ||
            scenario == 'partial' ||
            scenario == 'disconnected';
        if (hasGap) await f.controller.inputDisconnected(tagA, false);
        if (scenario == 'gap' || scenario == 'partial') {
          await f.controller.inputDisconnected(tagA, true);
        }
        final eligible = scenario != 'empty' && scenario != 'disconnected';
        if (eligible) await h.ready();
        final watch = Stopwatch()..start();
        int? persisted;
        int? commandStarted;
        int? recoveryEnded;
        int? finalCommit;
        f.store.onCommit = (phase) {
          if (phase == ActivityRecordingPhase.finalizing) {
            persisted ??= watch.elapsedMicroseconds;
          }
          if (phase == ActivityRecordingPhase.finished) {
            finalCommit = watch.elapsedMicroseconds;
          }
        };
        h.onStart = () async => commandStarted = watch.elapsedMicroseconds;
        final work = f.controller.finishActivityRecording(
          recordingId: r.recordingId,
        );
        if (eligible) {
          await pumpEventQueue();
          final offsets = scenario == 'gap'
              ? [1, 7, count + 10]
              : scenario == 'partial'
              ? [7]
              : <int>[];
          await h.send(h.meta(offsets.length));
          for (var i = 0; i < offsets.length; i++) {
            await h.send(
              h.chunk(
                t + offsets[i],
                index: i,
                packet: offsets[i] == 1 ? 2 : i + 10,
              ),
            );
          }
          await h.send(h.end(offsets.length));
          recoveryEnded = watch.elapsedMicroseconds;
        }
        final done = await work;
        final total = watch.elapsedMicroseconds;
        expect(done.phase, ActivityRecordingPhase.finished);
        expect(
          done.pointCount,
          count +
              (scenario == 'gap'
                  ? 2
                  : scenario == 'partial'
                  ? 1
                  : 0),
        );
        expect(
          done.routeQuality,
          hasGap && scenario != 'gap'
              ? ActivityRecordingRouteQuality.partial
              : ActivityRecordingRouteQuality.unknown,
        );
        expect(done.recoveryState, ActivityRecordingRecoveryState.idle);
        expect(h.requests.length, eligible ? 1 : 0);
        debugPrint(
          'AR2CB_PERF scenario=$scenario points=$count unit=us persistFinalizing=$persisted recovery=${commandStarted == null ? 0 : recoveryEnded! - commandStarted!} finalCommit=${finalCommit! - (recoveryEnded ?? persisted!)} total=$total',
        );
      } finally {
        await h.delete();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
