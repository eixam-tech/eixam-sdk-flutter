import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_integrity.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_record.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_route_sql.dart';
import 'package:flutter_test/flutter_test.dart';

import 'activity_recording_finalization_integrity_test.dart' show ValidationSpy;
import 'recording_test_support.dart';
import 'route_repair_test_support.dart' show seed, report;

/// Diagnostic host SQLite timings, separate from TAG's five-second catch-up cap.
void main() {
  for (final count in [0, 1000, 10000, 50000, 100000]) {
    test(
      'Finish integrity benchmark $count',
      () async {
        final f = await RecordingFixture.create();
        try {
          final r = await seed(f, count);
          final cutoff = count == 0
              ? f.now
              : r.lastSampleAt!.subtract(const Duration(microseconds: 1));
          final db = await f.raw();
          var validationUs = 0;
          var clippingUs = 0;
          var localTransactionUs = 0;
          var largestBatch = 0;
          try {
            final record = ActivityRecordingRecord.decode(
              (await db.query('recordings')).single,
            );
            // Measure the canonical validator directly, with its actual batch
            // bounds. It writes nothing and doesn't authorize a later transaction.
            final watch = Stopwatch()..start();
            await db.transaction((tx) async {
              final spy = ValidationSpy(tx);
              await ActivityRecordingIntegrity.beforeFinish(spy, record);
              largestBatch = spy.largestBatch;
            });
            validationUs = watch.elapsedMicroseconds;
            // Exercise the real cutoff path again in its own transaction. Roll
            // back the benchmark so the public Finish below still starts active.
            final rollback = StateError('benchmark-rollback');
            watch.reset();
            try {
              await db.transaction((tx) async {
                final spy = _ClippingTimer(tx);
                await ActivityRecordingRouteSql(spy).finish(record, cutoff);
                clippingUs = spy.clipping.elapsedMicroseconds;
                throw rollback;
              });
            } catch (error) {
              if (!identical(error, rollback)) rethrow;
            }
            localTransactionUs = watch.elapsedMicroseconds;
          } finally {
            await db.close();
          }
          final watch = Stopwatch()..start();
          final done = await f.controller.finishActivityRecording(
            recordingId: r.recordingId,
            endedAt: cutoff,
          );
          final totalUs = watch.elapsedMicroseconds;
          expect(done.phase, ActivityRecordingPhase.finished);
          expect(done.pointCount, count == 0 ? 0 : count - 1);
          expect(largestBatch, lessThanOrEqualTo(512));
          report('finish-integrity', {
            'points': count,
            'validation_us': validationUs,
            'clipping_aggregation_us': clippingUs,
            'cutoff_transaction_us': localTransactionUs,
            'total_finish_us': totalUs,
            'max_validation_batch': largestBatch,
          });
        } finally {
          await f.delete();
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}

class _ClippingTimer extends ValidationSpy {
  _ClippingTimer(super.inner);
  final clipping = Stopwatch();

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) {
    if (!clipping.isRunning) clipping.start();
    return super.delete(table, where: where, whereArgs: whereArgs);
  }
}
