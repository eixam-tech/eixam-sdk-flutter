import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_record.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_route_data.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_route_sql.dart';
import 'package:flutter_test/flutter_test.dart';

import 'recording_test_support.dart';
import 'route_repair_test_support.dart';

void main() {
  test(
    '100k continuous middle insertion has bounded structural work',
    () async {
      final f = await RecordingFixture.create();
      try {
        final r = await seed(f, 100000);
        final owner = ActivityRecordingOwner.forIdentity(
          f.backend,
          recordingUserA,
        );
        final record = (await f.database.transaction(
          (tx) => tx.byId(owner.scope, r.recordingId),
        ))!;
        final db = await f.raw();
        try {
          late ProfileSpy spy;
          late ActivityRecordingRecord result;
          var calculations = 0;
          final at = r.recordingStartedAt.add(
            const Duration(seconds: 100000, microseconds: 1),
          );
          final us = await timed(
            () => db.transaction((tx) async {
              spy = ProfileSpy(tx);
              result =
                  await ActivityRecordingRouteSql(
                    spy,
                    onEdgeCalculation: () => calculations++,
                  ).ingest(record, [
                    ActivityRecordingRouteEvidence(
                      at,
                      'middle',
                      SdkActivityRoutePoint(
                        stableSampleKey: 'middle',
                        sampledAt: at,
                        latitude: 41.005,
                        longitude: 2.005,
                        delivery: EixamDevicePositionDelivery.recovered,
                      ),
                    ),
                  ]);
            }),
          );
          final fetched = spy.queries
              .where((q) => q['table'] == 'route_points')
              .fold<int>(0, (n, q) => n + (q['rows'] as int));
          report('repair-work', {
            'n': 100000,
            'us': us,
            'rowsFetched': fetched,
            'rowsInspected': spy.repairRowsInspected,
            'queries': spy.queries,
            'rowsUpdated': spy.updates.length,
            'distanceEdgesChanged': spy.updates
                .where((u) => u['edge_distance'] != null)
                .length,
            'edgeCalculations': calculations,
          });
          expect(result.value.pointCount, 100001);
          expect(result.value.segmentCount, 1);
          expect(result.value.routeRevision, r.routeRevision + 1);
          expect(spy.updates, hasLength(2));
          expect(calculations, 2);
          expect(spy.repairRowsInspected, lessThan(10));
          expect(
            fetched,
            lessThan(100),
            reason:
                'An ordinary middle insertion must not materialize the 50k suffix.',
          );
        } finally {
          await db.close();
        }
      } finally {
        await f.delete();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
