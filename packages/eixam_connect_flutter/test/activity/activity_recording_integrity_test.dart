import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_record.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_route_data.dart';

import 'activity_recording_ingestion_test.dart' show batch, sample;
import 'recording_history_test_support.dart';
import 'recording_test_support.dart';

void main() {
  integrityMatrix();
  for (final corruption in [
    'empty-key',
    'empty-segment',
    'future-cursor',
    'gap-mismatch',
  ]) {
    test('persisted $corruption fails closed and preserves evidence', () async {
      final h = RecordingHistoryHarness();
      await h.create();
      final f = h.f;
      try {
        final r = await f.start(device: tagA);
        f.now = f.now.add(const Duration(seconds: 10));
        await f.controller.ingestLive(
          batch(f, [
            sample('a', r.recordingStartedAt),
            sample('b', r.recordingStartedAt.add(const Duration(seconds: 1))),
          ]),
        );
        if (corruption == 'gap-mismatch') {
          await f.controller.inputDisconnected(tagA, false);
          await f.controller.inputDisconnected(tagA, true);
        }
        if (corruption == 'future-cursor') await h.ready();
        final db = await f.raw();
        try {
          if (corruption == 'empty-key') {
            await db.update(
              'route_points',
              {'sample_key': ''},
              where: 'sample_key = ?',
              whereArgs: ['a'],
            );
          } else if (corruption == 'empty-segment') {
            await db.update(
              'route_points',
              {'segment_id': ''},
              where: 'sample_key = ?',
              whereArgs: ['a'],
            );
          } else if (corruption == 'future-cursor') {
            await db.insert('recording_recovery', {
              'recording_id': r.recordingId,
              'needed': 1,
              'processed_through': DateTime.utc(2099).microsecondsSinceEpoch,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          } else {
            await db.update('route_gaps', {
              'until_order': r.recordingStartedAt.microsecondsSinceEpoch,
            });
          }
          Future<List<Map<String, Object?>>> snapshot() async => [
            ...await db.query('recordings'),
            ...await db.query('route_points'),
            ...await db.query('route_gaps'),
            ...await db.query('recording_recovery'),
          ];
          final before = await snapshot();
          final operation = corruption == 'future-cursor'
              ? f.controller.recoverActivityRecordingHistory(
                  recordingId: r.recordingId,
                )
              : f.controller
                    .readActivityRecordingRoute(
                      recordingId: r.recordingId,
                      fromInclusive: corruption == 'gap-mismatch'
                          ? r.recordingStartedAt.add(const Duration(seconds: 2))
                          : null,
                    )
                    .toList();
          await expectLater(
            operation,
            throwsA(
              isA<ActivityRecordingException>().having(
                (e) => e.code,
                'sanitized integrity error',
                isIn([
                  'E_RECORDING_PERSISTENCE_FAILED',
                  'E_RECORDING_RESTORE_FAILED',
                ]),
              ),
            ),
          );
          expect(await snapshot(), before);
        } finally {
          await db.close();
        }
      } finally {
        await h.delete();
      }
    });
  }
}

final _integrityError = isA<ActivityRecordingException>().having(
  (e) => e.code,
  'code',
  isIn(['E_RECORDING_PERSISTENCE_FAILED', 'E_RECORDING_RESTORE_FAILED']),
);

Future<Map<String, List<Map<String, Object?>>>> _snapshot(Database db) async =>
    {
      for (final table in [
        'recordings',
        'route_points',
        'route_gaps',
        'recording_recovery',
      ])
        table: await db.query(table),
    };

void integrityMatrix() {
  for (final finished in [false, true]) {
    for (final corruption in [
      'empty-key',
      'empty-segment',
      'invalid-segment',
      'cursor-before-start',
      'cursor-after-last',
      'cursor-out-of-range',
      'cursor-not-integer',
      'gap-reversed',
      'gap-from-mismatch',
      'gap-until-mismatch',
      'gap-invalid-time',
      'gap-empty-id',
      'gap-invalid-id',
      'gap-invalid-reason',
      'gap-invalid-state',
      'gap-null-pair',
      'gap-open-integrity',
      'gap-reconciled-open',
      if (finished) 'gap-finished-open',
    ]) {
      test(
        '$corruption on ${finished ? 'finished' : 'active'} route rejects projection and mutation',
        () async {
          final f = await RecordingFixture.create();
          try {
            final r = await f.start(device: tagA);
            f.now = f.now.add(const Duration(seconds: 10));
            await f.controller.ingestLive(
              batch(f, [
                sample('a', r.recordingStartedAt),
                sample(
                  'b',
                  r.recordingStartedAt.add(const Duration(seconds: 1)),
                ),
              ]),
            );
            await f.controller.inputDisconnected(tagA, false);
            await f.controller.inputDisconnected(tagA, true);
            if (finished) {
              await f.controller.finishActivityRecording(
                recordingId: r.recordingId,
              );
            }
            final db = await f.raw();
            try {
              final start = r.recordingStartedAt;
              if (corruption == 'empty-key') {
                await db.update('route_points', {
                  'sample_key': '',
                }, where: "sample_key = 'a'");
              } else if (corruption.endsWith('segment')) {
                await db.update('route_points', {
                  'segment_id': corruption == 'empty-segment'
                      ? ''
                      : 'malformed',
                }, where: "sample_key = 'a'");
              } else if (corruption.startsWith('cursor')) {
                final Object cursor = switch (corruption) {
                  'cursor-before-start' => start.microsecondsSinceEpoch - 1,
                  'cursor-after-last' =>
                    start
                        .add(const Duration(seconds: 2))
                        .microsecondsSinceEpoch,
                  'cursor-out-of-range' => 9223372036854775807,
                  _ => 'malformed',
                };
                await db.insert(
                  'recording_recovery',
                  {
                    'recording_id': r.recordingId,
                    'needed': 1,
                    'processed_through': cursor,
                  },
                  conflictAlgorithm: ConflictAlgorithm.replace,
                );
              } else {
                final values = switch (corruption) {
                  'gap-reversed' => <String, Object?>{
                    'until_time': start.toIso8601String(),
                    'until_order': start.microsecondsSinceEpoch,
                  },
                  'gap-from-mismatch' => <String, Object?>{
                    'from_order': start.microsecondsSinceEpoch,
                  },
                  'gap-until-mismatch' => <String, Object?>{
                    'until_order': start.microsecondsSinceEpoch,
                  },
                  'gap-invalid-time' => <String, Object?>{
                    'from_time': '2026-99-99T00:00:00Z',
                  },
                  'gap-empty-id' => <String, Object?>{'gap_id': ''},
                  'gap-invalid-id' => <String, Object?>{'gap_id': 'malformed'},
                  'gap-invalid-reason' => <String, Object?>{
                    'reason': 'unsupported',
                  },
                  'gap-invalid-state' => <String, Object?>{
                    'state': 'unsupported',
                  },
                  'gap-null-pair' => <String, Object?>{'until_order': null},
                  'gap-open-integrity' => <String, Object?>{
                    'reason': 'rejectedSamples',
                    'until_time': null,
                    'until_order': null,
                  },
                  'gap-reconciled-open' => <String, Object?>{
                    'state': 'reconciled',
                    'until_time': null,
                    'until_order': null,
                  },
                  _ => <String, Object?>{
                    'until_time': null,
                    'until_order': null,
                  },
                };
                await db.update('route_gaps', values);
              }
              final before = await _snapshot(db);
              await expectLater(
                f.controller
                    .readActivityRecordingRoute(
                      recordingId: r.recordingId,
                      fromInclusive: corruption.startsWith('gap')
                          ? start.add(const Duration(seconds: 2))
                          : null,
                    )
                    .toList(),
                throwsA(_integrityError),
              );
              expect(await _snapshot(db), before);
              // Direct private store call tests rollback after a new row is inserted
              // but BEFORE malformed neighbour facts can be used by optimized repair.
              final owner = ActivityRecordingOwner.forIdentity(
                f.backend,
                recordingUserA,
              );
              await expectLater(
                f.database.transaction((tx) async {
                  final record = (await tx.byId(owner.scope, r.recordingId))!;
                  final at = start.add(const Duration(milliseconds: 500));
                  await tx.ingestRoute(record, [
                    ActivityRecordingRouteEvidence(
                      at,
                      'repair-attempt',
                      SdkActivityRoutePoint(
                        stableSampleKey: 'repair-attempt',
                        sampledAt: at,
                        latitude: 1,
                        longitude: 1,
                        delivery: EixamDevicePositionDelivery.recovered,
                      ),
                    ),
                  ]);
                }),
                throwsA(_integrityError),
              );
              expect(await _snapshot(db), before);
              if (!finished) {
                await expectLater(
                  f.controller.finishActivityRecording(
                    recordingId: r.recordingId,
                  ),
                  throwsA(_integrityError),
                );
                expect(await _snapshot(db), before);
              }
            } finally {
              await db.close();
            }
          } finally {
            await f.delete();
          }
        },
      );
    }
  }

  for (final empty in [false, true]) {
    test(
      'valid recovered cursor narrows atomically with historical Finish empty=$empty',
      () async {
        final f = await RecordingFixture.create();
        try {
          final r = await f.start(device: tagA);
          f.now = f.now.add(const Duration(seconds: 10));
          await f.controller.ingestLive(
            batch(f, [
              if (!empty) sample('a', r.recordingStartedAt),
              sample('b', r.recordingStartedAt.add(const Duration(seconds: 2))),
            ]),
          );
          final db = await f.raw();
          try {
            // Simulate the exact durable cursor produced by completed D1 settlement.
            await db.insert('recording_recovery', {
              'recording_id': r.recordingId,
              'processed_through': r.recordingStartedAt
                  .add(const Duration(seconds: 2))
                  .microsecondsSinceEpoch,
              'needed': 0,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
            final done = await f.controller.finishActivityRecording(
              recordingId: r.recordingId,
              endedAt: r.recordingStartedAt.add(const Duration(seconds: 1)),
            );
            expect(done.phase, ActivityRecordingPhase.finished);
            expect(done.pointCount, empty ? 0 : 1);
            expect(
              (await db.query(
                'recording_recovery',
              )).single['processed_through'],
              empty ? null : r.recordingStartedAt.microsecondsSinceEpoch,
            );
            expect(
              await f.controller
                  .readActivityRecordingRoute(recordingId: r.recordingId)
                  .toList(),
              hasLength(1),
            );
          } finally {
            await db.close();
          }
        } finally {
          await f.delete();
        }
      },
    );
  }
}
