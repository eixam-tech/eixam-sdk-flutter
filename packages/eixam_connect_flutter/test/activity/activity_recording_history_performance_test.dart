import 'dart:convert';

import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_history_sql.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as native;

import 'activity_recording_history_test_support.dart';
import 'recording_test_support.dart';

void main() {
  test(
    '100000 summaries: bounded deep/tied seeks and metadata-only query plans',
    () async {
      final f = await RecordingFixture.create();
      try {
        await seedHistory(f, []);
        final db = native.sqlite3.open(f.path);
        final template = historyRecord(f, 0).encode();
        final columns = template.keys.toList();
        final insert = db.prepare(
          'INSERT INTO recordings (${columns.join(',')}) '
          'VALUES (${List.filled(columns.length, '?').join(',')})',
        );
        final order = db.prepare(
          'INSERT INTO recording_history_order VALUES (?,?,?)',
        );
        final scope = template['owner_scope'] as String;
        final base = f.now.microsecondsSinceEpoch;
        db.execute('BEGIN');
        try {
          for (var i = 0; i < 100000; i++) {
            // Two 50k timestamp groups exercise deep seeks inside large ties.
            final at = f.now.add(Duration(microseconds: i ~/ 50000));
            final row = {
              ...template,
              'recording_id': historyId(i),
              'activity_session_id': 'large-$i',
              'ended_at': at.toIso8601String(),
            };
            insert.execute(columns.map((c) => row[c]).toList());
            order.execute([historyId(i), scope, at.microsecondsSinceEpoch]);
          }
          db.execute('COMMIT');
        } finally {
          insert.dispose();
          order.dispose();
          db.dispose();
        }
        final cold = Stopwatch()..start();
        final first = await f.controller.listFinishedActivityRecordings(
          limit: 20,
        );
        cold.stop();
        expect(first.items.first.recordingId, historyId(99999));
        final raw = await f.raw();
        await raw.transaction((tx) async {
          final trace = HistoryQueryTrace(tx);
          final sql = ActivityRecordingHistorySql(trace);
          final timings = <int>[];
          for (final key in [
            (base + 1, historyId(50002)),
            (base + 1, historyId(99980)),
            (base, historyId(25)),
          ]) {
            final watch = Stopwatch()..start();
            final result = await sql.page(
              scope,
              limit: 21,
              endedAtUs: key.$1,
              recordingId: key.$2,
            );
            timings.add(watch.elapsedMicroseconds);
            expect(result.length, lessThanOrEqualTo(21));
            final start = int.parse(key.$2, radix: 16) - 1;
            expect(
              result.map((r) => r.value.recordingId),
              List.generate(21, (i) => historyId(start - i)),
            );
          }
          expect(await sql.page('foreign-owner', limit: 21), isEmpty);
          final plans = <String>[];
          for (final query in trace.queries) {
            final plan = await tx.rawQuery(
              'EXPLAIN QUERY PLAN ${query.$1}',
              query.$2,
            );
            final details = plan.map((p) => p['detail'] as String).toList();
            expect(
              details.where((p) => p.contains('USE TEMP B-TREE')),
              isEmpty,
            );
            expect(
              details.where(
                (p) =>
                    p.contains('SCAN recordings') ||
                    p.contains('SCAN h') ||
                    p.contains('SCAN r'),
              ),
              isEmpty,
            );
            if (query.$1.contains('FROM recording_history_order h')) {
              expect(
                details.any(
                  (p) =>
                      p.contains('recording_history_page') &&
                      p.contains('SEARCH'),
                ),
                isTrue,
              );
              expect(
                details.any((p) => p.contains('sqlite_autoindex_recordings_1')),
                isTrue,
              );
              plans.addAll(details);
            }
          }
          debugPrint(
            'HISTORY_P1_HOST_SQLITE ${jsonEncode({'summaries': 100000, 'coldPreparationAndFirstPageUs': cold.elapsedMicroseconds, 'deepPageUs': timings, 'plans': plans.toSet().toList(), 'maximumSelectedSummaries': 21})}',
          );
        });
        await raw.close();
      } finally {
        await f.delete();
      }
    },
  );
}
