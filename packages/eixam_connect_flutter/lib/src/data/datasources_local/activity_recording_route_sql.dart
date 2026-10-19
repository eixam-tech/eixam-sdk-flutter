import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:sqflite/sqflite.dart';

import 'activity_recording_record.dart';
import 'activity_recording_integrity.dart';
import 'activity_recording_route_data.dart';

/// Transaction-local canonical route engine. Normal append touches only the
/// tail and new rows. Repairs stop when persisted predecessor, segment and edge
/// facts stabilize beyond the changed interval; genuine relabeling may go farther.
final class ActivityRecordingRouteSql {
  ActivityRecordingRouteSql(this.sql, {this.onEdgeCalculation});
  final DatabaseExecutor sql;
  // Private test seam; never emits route content or production diagnostics.
  final void Function()? onEdgeCalculation;

  Future<ActivityRecordingRecord> ingest(
    ActivityRecordingRecord record,
    List<ActivityRecordingRouteEvidence> evidence, {
    int? topologyChangedFrom,
    int? topologyChangedUntil,
  }) async {
    if (evidence.isEmpty && topologyChangedFrom == null) return record;
    final r = record.value;
    final id = r.recordingId;
    final allGaps = await ActivityRecordingIntegrity.gaps(sql, record);
    await ActivityRecordingIntegrity.recovery(sql, record);
    var gapCreated = false;
    final inserted = <String>{};
    var insertedCount = 0;
    int? changed = topologyChangedFrom;
    final affected = <({int from, int until})>[
      if (topologyChangedFrom != null)
        (
          from: topologyChangedFrom,
          until: topologyChangedUntil ?? 9223372036854775807,
        ),
    ];
    void affect(int at, [int? until]) {
      changed = changed == null || at < changed! ? at : changed;
      affected.add((from: at, until: until ?? at));
    }

    Future<void> gap(
      int from,
      int until,
      ActivityRecordingGapReason reason,
    ) async {
      final key = _identity('$id:${reason.name}:$from:$until');
      final exists = await sql.query(
        'route_gaps',
        columns: ['gap_id'],
        where: 'gap_id = ?',
        whereArgs: [key],
      );
      if (exists.isNotEmpty) return;
      await sql.insert('route_gaps', {
        'gap_id': key,
        'recording_id': id,
        'from_time': _time(from),
        'until_time': _time(until),
        'from_order': from,
        'until_order': until,
        'reason': reason.name,
        'state': ActivityRecordingGapState.unresolved.name,
      });
      gapCreated = true;
      affect(from, until);
    }

    // A deterministic first value also applies to collisions within one batch.
    final ordered = evidence.toList()
      ..sort((a, b) {
        final key = a.key.compareTo(b.key);
        return key != 0 ? key : _content(a).compareTo(_content(b));
      });
    // Inserts must be visible to later same-key/same-time checks in this txn.
    for (final item in ordered) {
      final at = item.at.microsecondsSinceEpoch;
      final point = item.point;
      if (point == null) {
        await gap(at, at, ActivityRecordingGapReason.rejectedSamples);
        continue;
      }
      final old = await sql.query(
        'route_points',
        where: 'recording_id = ? AND sample_key = ?',
        whereArgs: [id, item.key],
      );
      if (old.isNotEmpty) {
        ActivityRecordingIntegrity.point(old.single, record);
        if (!_same(old.single, point, r.deviceIdentity!)) {
          final prior = old.single['sample_order'] as int;
          await gap(
            math.min(at, prior),
            math.max(at, prior),
            ActivityRecordingGapReason.rejectedSamples,
          );
        }
        continue;
      }
      await sql.insert('route_points', {
        'recording_id': id,
        'sample_key': item.key,
        'sampled_at': point.sampledAt.toIso8601String(),
        'sample_order': at,
        'latitude': point.latitude,
        'longitude': point.longitude,
        'altitude_meters': point.altitudeMeters,
        'delivery': point.delivery.name,
        'device_identity': r.deviceIdentity,
        'segment_id': _segment(id, item.key),
      });
      inserted.add(item.key);
      insertedCount++;
      affect(at);
      final peers = await sql.query(
        'route_points',
        columns: ['sample_key'],
        where: 'recording_id = ? AND sample_order = ?',
        whereArgs: [id, at],
        limit: 2,
      );
      if (peers.length == 2) {
        await gap(at, at, ActivityRecordingGapReason.ambiguousTimestamp);
      }
    }
    if (changed == null) return record;

    final gaps = [
      for (final g in allGaps)
        if (g['state'] != ActivityRecordingGapState.reconciled.name) g,
    ];
    // Include integrity gaps added by this ingestion before repairing edges.
    if (gapCreated) {
      gaps
        ..clear()
        ..addAll(
          (await ActivityRecordingIntegrity.gaps(sql, record)).where(
            (g) => g['state'] != ActivityRecordingGapState.reconciled.name,
          ),
        );
    }
    final counters = await sql.query(
      'recordings',
      columns: ['distance_edge_count'],
      where: 'recording_id = ?',
      whereArgs: [id],
    );
    var edges = counters.single['distance_edge_count'] as int;
    var total = r.recordedDistanceMeters ?? 0.0;
    var segments = r.segmentCount;
    affected.sort((a, b) => a.from.compareTo(b.from));
    Future<List<Map<String, Object?>>> predecessor(int at) => sql.query(
      'route_points',
      where: 'recording_id = ? AND sample_order < ?',
      whereArgs: [id, at],
      orderBy: 'sample_order DESC, sample_key DESC',
      limit: 1,
    );
    var interval = 0;
    int? earliestStart;
    List<Map<String, Object?>>? nextPrior;
    while (interval < affected.length) {
      final current = affected[interval++];
      var through = current.until;
      final prior = nextPrior ?? await predecessor(current.from);
      nextPrior = null;
      if (prior.isNotEmpty) {
        ActivityRecordingIntegrity.point(prior.single, record);
      }
      final start = prior.isEmpty
          ? current.from
          : prior.single['sample_order'] as int;
      earliestStart ??= start;
      final before = await sql.query(
        'route_points',
        where: 'recording_id = ? AND sample_order < ?',
        whereArgs: [id, start],
        orderBy: 'sample_order DESC, sample_key DESC',
        limit: 1,
      );
      if (before.isNotEmpty) {
        ActivityRecordingIntegrity.point(before.single, record);
      }
      Map<String, Object?>? previous = before.isEmpty ? null : before.single;
      var gapIndex = 0;
      final pending = sql.batch();
      await for (final row in _repairRows(id, start)) {
        ActivityRecordingIntegrity.point(row, record);
        final key = row['sample_key'] as String;
        final time = row['sample_order'] as int;
        final prevTime = previous?['sample_order'] as int?;
        if (prevTime != null) {
          while (gapIndex < gaps.length &&
              gaps[gapIndex]['until_order'] != null &&
              (gaps[gapIndex]['until_order'] as int) < prevTime) {
            gapIndex++;
          }
        }
        var blocked = previous == null || time == prevTime;
        if (!blocked) {
          for (var i = gapIndex; i < gaps.length; i++) {
            final gap = gaps[i];
            final from = gap['from_order'] as int;
            if (from > time) break;
            final until = gap['until_order'] as int?;
            final disconnect =
                gap['reason'] ==
                ActivityRecordingGapReason.deviceUnavailable.name;
            if (disconnect
                ? from < time && (until == null || until > prevTime!)
                : until == null || until >= prevTime!) {
              blocked = true;
              break;
            }
          }
        }
        final oldEdge = (row['edge_distance'] as num?)?.toDouble();
        final prevKey = previous?['sample_key'] as String?;
        final edge = blocked
            ? null
            : row['previous_key'] == prevKey && oldEdge != null
            ? oldEdge
            : _edgeDistance(previous!, row);
        final segment = edge == null
            ? _segment(id, key)
            : previous!['segment_id'] as String;
        final wasNew = inserted.remove(key);
        if (!wasNew) {
          if (oldEdge == null) {
            segments--;
          } else {
            total -= oldEdge;
            edges--;
          }
        }
        if (edge == null) {
          segments++;
        } else {
          total += edge;
          edges++;
        }
        final stable =
            !wasNew &&
            row['previous_key'] == prevKey &&
            row['segment_id'] == segment &&
            oldEdge == edge;
        if (!stable) {
          pending.update(
            'route_points',
            {
              'previous_key': prevKey,
              'edge_distance': edge,
              'segment_id': segment,
            },
            where: 'recording_id = ? AND sample_key = ?',
            whereArgs: [id, key],
          );
        }
        previous = {...row, 'segment_id': segment};
        // Absorb overlapping/adjacent mutations while traversing their neighbours.
        while (interval < affected.length && affected[interval].from <= time) {
          through = math.max(through, affected[interval++].until);
        }
        if (stable && time > through) {
          if (interval < affected.length) {
            nextPrior = await predecessor(affected[interval].from);
            if (nextPrior.isNotEmpty &&
                ((nextPrior.single['sample_order'] as int) <= time ||
                    nextPrior.single['previous_key'] == key)) {
              through = math.max(through, affected[interval++].until);
              nextPrior = null;
              continue;
            }
          }
          break;
        }
      }
      // A later interval may use this repaired boundary as its predecessor.
      await pending.commit(noResult: true);
    }
    final first = await sql.query(
      'route_points',
      columns: ['sampled_at'],
      where: 'recording_id = ?',
      whereArgs: [id],
      orderBy: 'sample_order, sample_key',
      limit: 1,
    );
    final last = await sql.query(
      'route_points',
      columns: ['sampled_at'],
      where: 'recording_id = ?',
      whereArgs: [id],
      orderBy: 'sample_order DESC, sample_key DESC',
      limit: 1,
    );
    final count = Sqflite.firstIntValue(
      await sql.rawQuery(
        "SELECT COUNT(*) FROM route_gaps WHERE recording_id = ? AND state != 'reconciled'",
        [id],
      ),
    )!;
    final issues = {...r.issues};
    if (gaps.any(
      (g) => g['reason'] == ActivityRecordingGapReason.rejectedSamples.name,
    )) {
      issues.add(ActivityRecordingIssue.invalidSamples);
    }
    if (gaps.any(
      (g) => g['reason'] == ActivityRecordingGapReason.ambiguousTimestamp.name,
    )) {
      issues.add(ActivityRecordingIssue.clockUncertain);
    }
    final updated = ActivityRecordingRecord.decode({
      ...record.encode(),
      'point_count': r.pointCount + insertedCount,
      'segment_count': segments,
      'unresolved_gap_count': count,
      'first_sample_at': first.isEmpty ? null : first.single['sampled_at'],
      'last_sample_at': last.isEmpty ? null : last.single['sampled_at'],
      'distance_meters': edges == 0 ? null : math.max(0.0, total),
      'route_revision': r.routeRevision + 1,
      'previous_route_revision': r.routeRevision,
      'route_changed_from': _time(earliestStart!),
      'route_quality': count == 0
          ? ActivityRecordingRouteQuality.unknown.name
          : ActivityRecordingRouteQuality.partial.name,
      'issues': jsonEncode(issues.map((e) => e.name).toList()..sort()),
    });
    await sql.update(
      'recordings',
      {...updated.encode(), 'distance_edge_count': edges},
      where: 'recording_id = ? AND owner_scope = ?',
      whereArgs: [id, record.owner.scope],
    );
    return updated;
  }

  double _edgeDistance(
    Map<String, Object?> previous,
    Map<String, Object?> row,
  ) {
    onEdgeCalculation?.call();
    return haversine(
      previous['latitude'] as num,
      previous['longitude'] as num,
      row['latitude'] as num,
      row['longitude'] as num,
    );
  }

  // This is repair traversal only; public route paging SQL remains unchanged.
  Stream<Map<String, Object?>> _repairRows(String id, int start) async* {
    Map<String, Object?>? after;
    while (true) {
      final rows = await sql.query(
        'route_points',
        where: after == null
            ? 'recording_id = ? AND sample_order >= ?'
            : 'recording_id = ? AND sample_order >= ? AND (sample_order > ? OR sample_key > ?)',
        whereArgs: after == null
            ? [id, start]
            : [
                id,
                after['sample_order'],
                after['sample_order'],
                after['sample_key'],
              ],
        orderBy: 'sample_order, sample_key',
        limit: 32,
      );
      for (final row in rows) {
        yield row;
      }
      if (rows.length < 32) return;
      after = rows.last;
    }
  }

  /// Clip a caller's fixed cutoff atomically with the finalizing barrier.
  Future<ActivityRecordingRecord> finish(
    ActivityRecordingRecord record,
    DateTime cutoff,
  ) async {
    final id = record.value.recordingId;
    await ActivityRecordingIntegrity.beforeFinish(sql, record);
    await ActivityRecordingIntegrity.gaps(sql, record);
    final recovery = await ActivityRecordingIntegrity.recovery(sql, record);
    // A resumed intent already owns its clipped route and cutoff. Validation
    // above is required again; rewriting that committed intent is unnecessary.
    if (record.value.phase == ActivityRecordingPhase.finalizing) return record;
    final time = cutoff.toUtc().microsecondsSinceEpoch;
    final removed = await sql.delete(
      'route_points',
      where: 'recording_id = ? AND sample_order > ?',
      whereArgs: [id, time],
    );
    final removedGaps = await sql.delete(
      'route_gaps',
      where: 'recording_id = ? AND from_order > ?',
      whereArgs: [id, time],
    );
    final clipped = await sql.update(
      'route_gaps',
      {'until_time': _time(time), 'until_order': time},
      where: 'recording_id = ? AND (until_order IS NULL OR until_order > ?)',
      whereArgs: [id, time],
    );
    ActivityRecordingRecord result;
    int? edges;
    if (removed == 0 && removedGaps == 0 && clipped == 0) {
      result = record.transition(
        phase: ActivityRecordingPhase.finalizing,
        endedAt: cutoff,
      );
    } else {
      final totals = (await sql.rawQuery(
        '''SELECT COUNT(*) AS n,
        COUNT(DISTINCT segment_id) AS segments, COUNT(edge_distance) AS edges,
        SUM(edge_distance) AS distance FROM route_points WHERE recording_id = ?''',
        [id],
      )).single;
      edges = totals['edges'] as int;
      final first = await sql.query(
        'route_points',
        columns: ['sampled_at'],
        where: 'recording_id = ?',
        whereArgs: [id],
        orderBy: 'sample_order, sample_key',
        limit: 1,
      );
      final last = await sql.query(
        'route_points',
        columns: ['sampled_at'],
        where: 'recording_id = ?',
        whereArgs: [id],
        orderBy: 'sample_order DESC, sample_key DESC',
        limit: 1,
      );
      final gapCount = Sqflite.firstIntValue(
        await sql.rawQuery(
          "SELECT COUNT(*) FROM route_gaps WHERE recording_id = ? AND state != 'reconciled'",
          [id],
        ),
      )!;
      final reasons = (await sql.query(
        'route_gaps',
        columns: ['reason'],
        where: 'recording_id = ?',
        whereArgs: [id],
        distinct: true,
      )).map((row) => row['reason']).toSet();
      final issues = {...record.value.issues}
        ..remove(ActivityRecordingIssue.invalidSamples)
        ..remove(ActivityRecordingIssue.clockUncertain);
      if (reasons.contains(ActivityRecordingGapReason.rejectedSamples.name)) {
        issues.add(ActivityRecordingIssue.invalidSamples);
      }
      if (reasons.contains(
        ActivityRecordingGapReason.ambiguousTimestamp.name,
      )) {
        issues.add(ActivityRecordingIssue.clockUncertain);
      }
      result = ActivityRecordingRecord.decode({
        ...record.encode(),
        'phase': ActivityRecordingPhase.finalizing.name,
        'ended_at': cutoff.toUtc().toIso8601String(),
        'point_count': totals['n'],
        'segment_count': totals['segments'],
        'first_sample_at': first.isEmpty ? null : first.single['sampled_at'],
        'last_sample_at': last.isEmpty ? null : last.single['sampled_at'],
        'distance_meters': totals['distance'],
        'unresolved_gap_count': gapCount,
        'issues': jsonEncode(
          issues.map((issue) => issue.name).toList()..sort(),
        ),
        'route_quality': gapCount == 0
            ? ActivityRecordingRouteQuality.unknown.name
            : ActivityRecordingRouteQuality.partial.name,
        'previous_route_revision': record.value.routeRevision,
        'route_revision': record.value.routeRevision + 1,
        'route_changed_from': last.isEmpty
            ? _time(time)
            : last.single['sampled_at'],
      });
    }
    final cursor = recovery?['processed_through'] as int?;
    final last = result.value.lastSampleAt?.microsecondsSinceEpoch;
    if (cursor != null && (last == null || cursor > last)) {
      // The OLD cursor was valid. A user cutoff narrows its durable window;
      // this is part of clipping, never a clamp/repair of corrupt stored input.
      await sql.update(
        'recording_recovery',
        {'processed_through': last},
        where: 'recording_id = ?',
        whereArgs: [id],
      );
    }
    await sql.update(
      'recordings',
      {...result.encode(), if (edges != null) 'distance_edge_count': edges},
      where: 'recording_id = ? AND owner_scope = ?',
      whereArgs: [id, record.owner.scope],
    );
    return result;
  }

  Future<ActivityRecordingRouteSlice> page(
    ActivityRecordingRecord record, {
    DateTime? fromInclusive,
    ActivityRecordingRouteCursor? after,
    required int pageSize,
  }) async {
    final id = record.value.recordingId;
    await ActivityRecordingIntegrity.gaps(sql, record);
    await ActivityRecordingIntegrity.recovery(sql, record);
    final from = fromInclusive?.toUtc().microsecondsSinceEpoch;
    final args = <Object?>[
      id,
      if (from != null) from,
      id,
      if (from != null) from,
    ];
    var cursor = '';
    if (after != null) {
      cursor =
          'WHERE (t > ? OR (t = ? AND (kind > ? OR (kind = ? AND k > ?))))';
      args.addAll([after.time, after.time, after.kind, after.kind, after.key]);
    }
    args.add(pageSize + 1);
    final rows = await sql.rawQuery('''SELECT * FROM (
      SELECT sample_order AS t, 1 AS kind, sample_key AS k, sampled_at,
        latitude, longitude, altitude_meters, delivery, segment_id, device_identity,
        NULL AS until_time, NULL AS reason, NULL AS state
      FROM route_points WHERE recording_id = ? ${from == null ? '' : 'AND sample_order >= ?'}
      UNION ALL
      SELECT from_order AS t, 0 AS kind, gap_id AS k, from_time AS sampled_at,
        NULL, NULL, NULL, NULL, NULL, NULL, until_time, reason, state
      FROM route_gaps WHERE recording_id = ? ${from == null ? '' : 'AND (until_order IS NULL OR until_order >= ?)'}
      ) $cursor ORDER BY t, kind, k LIMIT ?''', args);
    final terminal = rows.length <= pageSize;
    final selected = rows.take(pageSize).toList();
    final segments = <SdkActivityRouteSegment>[];
    final gaps = <SdkActivityRouteGap>[];
    var points = <SdkActivityRoutePoint>[];
    String? segment;
    void flush() {
      if (points.isNotEmpty) {
        segments.add(
          SdkActivityRouteSegment(segmentId: segment!, points: points),
        );
      }
      points = [];
    }

    for (final row in selected) {
      final at = DateTime.parse(row['sampled_at'] as String);
      if (!at.isUtc || at.microsecondsSinceEpoch != row['t']) {
        throw const FormatException();
      }
      if (row['kind'] == 0) {
        final until = row['until_time'] == null
            ? null
            : DateTime.parse(row['until_time'] as String);
        if (until != null && (!until.isUtc || until.isBefore(at))) {
          throw const FormatException();
        }
        gaps.add(
          SdkActivityRouteGap(
            gapId: row['k'] as String,
            from: at,
            until: until,
            reason: ActivityRecordingGapReason.values.byName(
              row['reason'] as String,
            ),
            state: ActivityRecordingGapState.values.byName(
              row['state'] as String,
            ),
          ),
        );
      } else {
        ActivityRecordingIntegrity.point({
          ...row,
          'sample_key': row['k'],
          'sample_order': row['t'],
        }, record);
        final lat = (row['latitude'] as num).toDouble();
        final lon = (row['longitude'] as num).toDouble();
        final alt = (row['altitude_meters'] as num?)?.toDouble();
        if (row['device_identity'] != record.value.deviceIdentity ||
            !EixamGeoCoordinates.isValidFix(lat, lon) ||
            (alt != null && !alt.isFinite) ||
            at.isBefore(record.value.recordingStartedAt) ||
            (record.value.endedAt != null &&
                at.isAfter(record.value.endedAt!))) {
          throw const FormatException();
        }
        if (segment != row['segment_id']) {
          flush();
          segment = row['segment_id'] as String;
        }
        points.add(
          SdkActivityRoutePoint(
            stableSampleKey: row['k'] as String,
            sampledAt: at,
            latitude: lat,
            longitude: lon,
            altitudeMeters: alt,
            delivery: EixamDevicePositionDelivery.values.byName(
              row['delivery'] as String,
            ),
          ),
        );
      }
    }
    flush();
    final tail = selected.isEmpty ? null : selected.last;
    return ActivityRecordingRouteSlice(
      segments,
      gaps,
      terminal,
      tail == null
          ? null
          : ActivityRecordingRouteCursor(
              tail['t'] as int,
              tail['kind'] as int,
              tail['k'] as String,
            ),
    );
  }

  static String _identity(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  static String _segment(String id, String key) => _identity('$id:$key');
  static String _time(int micros) => DateTime.fromMicrosecondsSinceEpoch(
    micros,
    isUtc: true,
  ).toIso8601String();
  static String _content(ActivityRecordingRouteEvidence e) => jsonEncode([
    e.at.microsecondsSinceEpoch,
    e.point?.latitude,
    e.point?.longitude,
    e.point?.altitudeMeters,
    e.point?.delivery.name,
  ]);
  static bool _same(
    Map<String, Object?> row,
    SdkActivityRoutePoint p,
    String device,
  ) =>
      row['device_identity'] == device &&
      row['sample_order'] == p.sampledAt.microsecondsSinceEpoch &&
      row['latitude'] == p.latitude &&
      row['longitude'] == p.longitude &&
      row['altitude_meters'] == p.altitudeMeters;

  static double haversine(num lat1, num lon1, num lat2, num lon2) {
    final radians = math.pi / 180;
    final dlat = (lat2 - lat1) * radians;
    final dlon = (lon2 - lon1) * radians;
    final a =
        math.pow(math.sin(dlat / 2), 2) +
        math.cos(lat1 * radians) *
            math.cos(lat2 * radians) *
            math.pow(math.sin(dlon / 2), 2);
    return 6371000 * 2 * math.asin(math.sqrt(a.clamp(0.0, 1.0)));
  }
}
