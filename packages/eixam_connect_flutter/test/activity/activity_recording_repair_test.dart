import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_record.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_route_data.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_route_sql.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_recovery_sql.dart';
import 'package:flutter_test/flutter_test.dart';

import 'activity_recording_ingestion_test.dart' show batch, sample;
import 'recording_test_support.dart';
import 'route_repair_test_support.dart';

void main() {
  for (final multiple in [false, true]) {
    test(
      'pending to unresolved gap state stops after stable local context multiple=$multiple',
      () async {
        final f = await RecordingFixture.create();
        try {
          final r = await f.start(device: tagA);
          await f.controller.inputDisconnected(tagA, false);
          f.now = f.now.add(const Duration(hours: 1));
          await f.controller.ingestLive(
            batch(f, [
              for (var i = 0; i < 1000; i++)
                sample(
                  'p$i',
                  r.recordingStartedAt.add(Duration(seconds: i * 2)),
                ),
            ]),
          );
          if (multiple) {
            await f.controller.inputDisconnected(tagA, false);
            await f.controller.inputDisconnected(tagA, true);
            await f.controller.inputDisconnected(tagA, false);
            f.now = f.now.add(const Duration(hours: 1));
            await f.controller.inputDisconnected(tagA, true);
          }
          final db = await f.raw();
          try {
            final record = ActivityRecordingRecord.decode(
              (await db.query('recordings')).single,
            );
            final points = await db.query(
              'route_points',
              orderBy: 'sample_order,sample_key',
            );
            late ProfileSpy spy;
            final after = await db.transaction((tx) {
              spy = ProfileSpy(tx);
              return ActivityRecordingRecoverySql(
                spy,
              ).settle(record, completed: false);
            });
            report('gap-state-work', {
              'multiple': multiple,
              'fetched': spy.pointRowsFetched,
              'inspected': spy.repairRowsInspected,
              'updated': spy.updates.length,
            });
            expect(spy.pointRowsFetched, lessThan(100));
            expect(spy.repairRowsInspected, lessThan(10));
            expect(spy.updates, isEmpty);
            expect(
              await db.query(
                'route_points',
                orderBy: 'sample_order,sample_key',
              ),
              points,
            );
            expect(after.value.segmentCount, record.value.segmentCount);
            expect(
              after.value.recordedDistanceMeters,
              record.value.recordedDistanceMeters,
            );
            expect(after.value.pointCount, 1000);
            expect(after.value.routeRevision, record.value.routeRevision + 1);
            expect(after.value.routeChangedFrom, r.recordingStartedAt);
            final gaps = await db.query('route_gaps');
            expect(gaps, hasLength(multiple ? 2 : 1));
            expect(gaps.every((g) => g['state'] == 'unresolved'), isTrue);
          } finally {
            await db.close();
          }
        } finally {
          await f.delete();
        }
      },
    );
  }

  test(
    'local mutation retains integrity gap ending at context predecessor',
    () async {
      final f = await RecordingFixture.create();
      try {
        final r = await f.start(device: tagA);
        f.now = f.now.add(const Duration(minutes: 1));
        await f.controller.ingestLive(
          batch(f, [
            sample('a', r.recordingStartedAt, longitude: 1),
            sample('b', r.recordingStartedAt, longitude: 2),
            sample(
              'c',
              r.recordingStartedAt.add(const Duration(seconds: 10)),
              longitude: 3,
            ),
            sample(
              'd',
              r.recordingStartedAt.add(const Duration(seconds: 20)),
              longitude: 5,
            ),
          ]),
        );
        final before = (await f.controller.getActiveActivityRecording())!;
        final db = await f.raw();
        try {
          final original = (await db.query(
            'route_points',
            where: "sample_key = 'c'",
          )).single;
          expect(original['edge_distance'], isNull);
          await f.controller.ingestLive(
            batch(f, [
              sample(
                'e',
                r.recordingStartedAt.add(const Duration(seconds: 15)),
                longitude: 4,
              ),
            ]),
          );
          final after = (await f.controller.getActiveActivityRecording())!;
          final context = (await db.query(
            'route_points',
            where: "sample_key = 'c'",
          )).single;
          expect(context, original);
          expect(after.segmentCount, 3);
          expect(after.unresolvedGapCount, 1);
          expect(
            after.recordedDistanceMeters,
            closeTo(before.recordedDistanceMeters!, 1e-7),
          );
          expect(after.routeRevision, before.routeRevision + 1);
          expect(
            after.routeChangedFrom,
            r.recordingStartedAt.add(const Duration(seconds: 10)),
          );
        } finally {
          await db.close();
        }
      } finally {
        await f.delete();
      }
    },
  );

  test(
    'batch coalesces intervals through previously recovered local neighbours',
    () async {
      final f = await RecordingFixture.create();
      try {
        final r = await seed(f, 1000);
        final db = await f.raw();
        try {
          var record = ActivityRecordingRecord.decode(
            (await db.query('recordings')).single,
          );
          List<ActivityRecordingRouteEvidence> evidence(int micros) => [
            for (var j = 0; j < 100; j++)
              ActivityRecordingRouteEvidence(
                r.recordingStartedAt.add(
                  Duration(seconds: 1000 + j * 2, microseconds: micros),
                ),
                'middle-$micros-$j',
                SdkActivityRoutePoint(
                  stableSampleKey: 'middle-$micros-$j',
                  sampledAt: r.recordingStartedAt.add(
                    Duration(seconds: 1000 + j * 2, microseconds: micros),
                  ),
                  latitude: 41,
                  longitude: 2,
                  delivery: EixamDevicePositionDelivery.recovered,
                ),
              ),
          ];
          for (final micros in [1, 2]) {
            record = await db.transaction(
              (tx) => ActivityRecordingRouteSql(
                tx,
              ).ingest(record, evidence(micros)),
            );
          }
          late ProfileSpy spy;
          final after = await db.transaction((tx) {
            spy = ProfileSpy(tx);
            return ActivityRecordingRouteSql(spy).ingest(record, evidence(3));
          });
          expect(after.value.pointCount, 1300);
          expect(after.value.segmentCount, 1);
          expect(after.value.routeRevision, record.value.routeRevision + 1);
          expect(spy.repairRowsInspected, lessThan(500));
          expect(spy.pointRowsFetched, lessThan(650));
        } finally {
          await db.close();
        }
      } finally {
        await f.delete();
      }
    },
  );

  test(
    'middle repair rollback preserves durable neighbours and exact retry after restart',
    () async {
      var f = await RecordingFixture.create();
      try {
        final r = await f.start(device: tagA);
        f.now = f.now.add(const Duration(minutes: 1));
        await f.controller.ingestLive(
          batch(f, [
            sample('a', r.recordingStartedAt),
            sample(
              'c',
              r.recordingStartedAt.add(const Duration(seconds: 2)),
              longitude: 3,
            ),
          ]),
        );
        final before = (await f.controller.getActiveActivityRecording())!;
        final middle = sample(
          'b',
          r.recordingStartedAt.add(const Duration(seconds: 1)),
          longitude: 2,
        );
        f.store.failNextWrite = true;
        await expectLater(
          f.controller.ingestLive(batch(f, [middle])),
          throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
        );
        final db = await f.raw();
        try {
          expect((await db.query('route_points')).map((p) => p['sample_key']), [
            'a',
            'c',
          ]);
          expect(
            (await db.query('recordings')).single['route_revision'],
            before.routeRevision,
          );
        } finally {
          await db.close();
        }
        final directory = f.directory;
        final sessions = f.sessionStore;
        await f.dispose();
        f = await RecordingFixture.create(
          directory: directory,
          sessionStore: sessions,
        );
        f.now = r.recordingStartedAt.add(const Duration(minutes: 1));
        expect(
          (await f.controller.getActiveActivityRecording())!.routeRevision,
          before.routeRevision,
        );
        await f.controller.ingestLive(batch(f, [middle]));
        final after = (await f.controller.getActiveActivityRecording())!;
        expect(after.pointCount, 3);
        expect(after.segmentCount, 1);
        expect(
          after.recordedDistanceMeters,
          closeTo(before.recordedDistanceMeters!, 1e-7),
        );
        expect(after.routeRevision, before.routeRevision + 1);
      } finally {
        await f.delete();
      }
    },
  );
}
