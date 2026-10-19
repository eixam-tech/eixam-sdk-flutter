import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_record.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_route_data.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_route_sql.dart';
import 'package:flutter_test/flutter_test.dart';

import 'recording_test_support.dart';
import 'route_repair_test_support.dart';

/// Actual host SQLite transactions; structural work matters more than timings.
/// Operations accumulate on the seeded route identically in baseline/fixed runs.
void main() {
  for (final n in [1000, 10000, 50000, 100000]) {
    test(
      '$n route repair benchmark matrix',
      () async {
        final f = await RecordingFixture.create();
        try {
          final r = await seed(f, n);
          final db = await f.raw();
          try {
            var record = ActivityRecordingRecord.decode(
              (await db.query('recordings')).single,
            );
            var ordinal = 0;
            Future<void> run(
              String scenario,
              int offset,
              int count, {
              bool individual = false,
            }) async {
              final micros = ++ordinal;
              var calculations = 0;
              final spies = <ProfileSpy>[];
              final before = record;
              final us = await timed(() async {
                final evidence = [
                  for (var j = 0; j < count; j++)
                    ActivityRecordingRouteEvidence(
                      r.recordingStartedAt.add(
                        Duration(
                          seconds: 2 * (offset + j),
                          microseconds: micros,
                        ),
                      ),
                      '$scenario-$j',
                      SdkActivityRoutePoint(
                        stableSampleKey: '$scenario-$j',
                        sampledAt: r.recordingStartedAt.add(
                          Duration(
                            seconds: 2 * (offset + j),
                            microseconds: micros,
                          ),
                        ),
                        latitude: 41 + (offset + j) / 1e7,
                        longitude: 2 + (offset + j) / 1e7,
                        delivery: EixamDevicePositionDelivery.recovered,
                      ),
                    ),
                ];
                for (final chunk
                    in individual ? evidence.map((e) => [e]) : [evidence]) {
                  record = await db.transaction((tx) async {
                    final spy = ProfileSpy(tx);
                    spies.add(spy);
                    return ActivityRecordingRouteSql(
                      spy,
                      onEdgeCalculation: () => calculations++,
                    ).ingest(record, chunk);
                  });
                }
              });
              final sum = (await db.rawQuery(
                'SELECT SUM(edge_distance) AS d, COUNT(edge_distance) AS edges, '
                'COUNT(DISTINCT segment_id) AS segments FROM route_points',
              )).single;
              expect(record.value.pointCount, before.value.pointCount + count);
              expect(record.value.segmentCount, 1);
              expect(record.value.unresolvedGapCount, 0);
              expect(sum['segments'], 1);
              expect(sum['edges'], record.value.pointCount - 1);
              expect(
                record.value.recordedDistanceMeters,
                closeTo((sum['d'] as num).toDouble(), 1e-7),
              );
              expect(
                record.value.routeRevision,
                before.value.routeRevision + (individual ? count : 1),
              );
              report('repair-benchmark', {
                'n': n,
                'scenario': scenario,
                'inserted': count,
                'us': us,
                'transactions': spies.length,
                'rowsFetched': spies.fold<int>(
                  0,
                  (a, s) => a + s.pointRowsFetched,
                ),
                'rowsInspected': spies.fold<int>(
                  0,
                  (a, s) => a + s.repairRowsInspected,
                ),
                'rowsUpdated': spies.fold<int>(
                  0,
                  (a, s) => a + s.updates.length,
                ),
                'edgeCalculations': calculations,
                'edgeUpdates': spies
                    .expand((s) => s.updates)
                    .where((u) => u['edge_distance'] != null)
                    .length,
                'segments': record.value.segmentCount,
                'gaps': record.value.unresolvedGapCount,
                'distance': record.value.recordedDistanceMeters,
              });
            }

            await run('append-1', n, 1);
            await run('middle-1', n ~/ 2, 1);
            await run('middle-100-individual', n ~/ 2, 100, individual: true);
            await run('middle-100-bulk', n ~/ 2, 100);
            await run('suffix-10', n - 10, 10);
            await run('suffix-500', n - 500, 500);
            if (n == 10000) await run('recovered-middle-2000', n ~/ 2, 2000);
            if (n == 100000) await run('recovered-window-100', n ~/ 3, 100);
          } finally {
            await db.close();
          }
        } finally {
          await f.delete();
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }
}
