import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_record.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'recording_test_support.dart';

/// Host SQLite metadata measurements only. No retention or timing thresholds.
void main() {
  for (final count in [1, 100, 1000]) {
    test(
      '$count retained metadata rows: lifecycle and restore measurement',
      () async {
        var f = await RecordingFixture.create();
        Future<int> measure(Future<void> Function() action) async {
          final timer = Stopwatch()..start();
          await action();
          return timer.elapsedMicroseconds;
        }

        try {
          final owner = ActivityRecordingOwner.forIdentity(
            f.backend,
            recordingUserA,
          );
          final open = await measure(() async {
            await f.database.transaction((tx) => tx.reconcileOwner(owner));
          });
          await f.database.transaction((tx) async {
            for (var i = 0; i < count; i++) {
              await tx.insert(
                ActivityRecordingRecord(
                  owner,
                  SdkActivityRecording(
                    recordingId: i.toRadixString(16).padLeft(32, '0'),
                    activitySessionId: 'fixture-$i',
                    activityKey: 'mountain',
                    activitySessionStartedAt: f.now,
                    recordingStartedAt: f.now,
                    endedAt: f.now,
                    phase: ActivityRecordingPhase.finished,
                    inputState: ActivityRecordingInputState.unbound,
                    recoveryState: ActivityRecordingRecoveryState.idle,
                    routeQuality: ActivityRecordingRouteQuality.unknown,
                  ),
                ),
              );
            }
          });
          late SdkActivityRecording recording;
          final start = await measure(() async => recording = await f.start());
          final lookup = await measure(() async {
            expect(
              (await f.controller.getActivityRecording(
                recordingId: '00000000000000000000000000000000',
              ))?.phase,
              ActivityRecordingPhase.finished,
            );
          });
          final finish = await measure(() async {
            await f.controller.finishActivityRecording(
              recordingId: recording.recordingId,
            );
          });
          final directory = f.directory;
          final sessions = f.sessionStore;
          await f.dispose();
          f = await RecordingFixture.create(
            directory: directory,
            sessionStore: sessions,
          );
          final restore = await measure(() async {
            expect(await f.controller.getActiveActivityRecording(), isNull);
            expect(
              (await f.controller.getActivityRecording(
                recordingId: recording.recordingId,
              ))?.phase,
              ActivityRecordingPhase.finished,
            );
          });
          final raw = await f.raw();
          expect(
            (await raw.rawQuery(
              'SELECT COUNT(*) AS n FROM recordings',
            )).single['n'],
            count + 1,
          );
          await raw.close();
          debugPrint(
            'AR2A_PERF rows=$count unit=us open=$open start=$start lookup=$lookup finish=$finish restore=$restore',
          );
        } finally {
          await f.delete();
        }
      },
    );
  }
}
