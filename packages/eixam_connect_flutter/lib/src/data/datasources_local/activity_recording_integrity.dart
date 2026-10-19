import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:sqflite/sqflite.dart';

import 'activity_recording_record.dart';

/// Persisted facts are validated before topology, filtering or public projection.
/// Failures intentionally contain no stored values; the store sanitizes errors.
abstract final class ActivityRecordingIntegrity {
  static final _digest = RegExp(r'^[a-f0-9]{64}$');

  static String text(Object? value) {
    if (value is! String || value.isEmpty) throw const FormatException();
    return value;
  }

  static DateTime time(Object? value, Object? order) {
    final raw = text(value);
    final at = DateTime.parse(raw);
    if (!at.isUtc ||
        at.toIso8601String() != raw ||
        order is! int ||
        at.microsecondsSinceEpoch != order) {
      throw const FormatException();
    }
    return at;
  }

  static void point(Map<String, Object?> row, ActivityRecordingRecord record) {
    text(row['sample_key']);
    if (!_digest.hasMatch(text(row['segment_id']))) {
      throw const FormatException();
    }
    final previous = row['previous_key'];
    if (previous != null) text(previous);
    final at = time(row['sampled_at'], row['sample_order']);
    final r = record.value;
    final lat = row['latitude'];
    final lon = row['longitude'];
    final altitude = row['altitude_meters'];
    final edge = row['edge_distance'];
    if (row['device_identity'] != r.deviceIdentity ||
        lat is! num ||
        lon is! num ||
        !EixamGeoCoordinates.isValidFix(lat.toDouble(), lon.toDouble()) ||
        (altitude != null && (altitude is! num || !altitude.isFinite)) ||
        (edge != null && (edge is! num || !edge.isFinite || edge < 0)) ||
        at.isBefore(r.recordingStartedAt) ||
        (r.endedAt != null && at.isAfter(r.endedAt!))) {
      throw const FormatException();
    }
    EixamDevicePositionDelivery.values.byName(text(row['delivery']));
  }

  static void gap(Map<String, Object?> row, ActivityRecordingRecord record) {
    final r = record.value;
    final id = text(row['gap_id']);
    final reason = ActivityRecordingGapReason.values.byName(
      text(row['reason']),
    );
    final state = ActivityRecordingGapState.values.byName(text(row['state']));
    final disconnectId = RegExp('^${r.recordingId}:disconnect:[0-9]+\$');
    if (!_digest.hasMatch(id) &&
        !(reason == ActivityRecordingGapReason.deviceUnavailable &&
            disconnectId.hasMatch(id))) {
      throw const FormatException();
    }
    final from = time(row['from_time'], row['from_order']);
    final untilRaw = row['until_time'];
    if ((untilRaw == null) != (row['until_order'] == null)) {
      throw const FormatException();
    }
    final until = untilRaw == null ? null : time(untilRaw, row['until_order']);
    if (from.isBefore(r.recordingStartedAt) ||
        (until != null && until.isBefore(from)) ||
        (until == null &&
            (reason != ActivityRecordingGapReason.deviceUnavailable ||
                state == ActivityRecordingGapState.reconciled ||
                r.phase != ActivityRecordingPhase.active)) ||
        (r.endedAt != null &&
            (from.isAfter(r.endedAt!) ||
                until == null ||
                until.isAfter(r.endedAt!)))) {
      throw const FormatException();
    }
  }

  /// Validate before numeric overlap/state predicates can hide corrupt gaps.
  static Future<List<Map<String, Object?>>> gaps(
    DatabaseExecutor sql,
    ActivityRecordingRecord record,
  ) async {
    final rows = await sql.query(
      'route_gaps',
      where: 'recording_id = ?',
      whereArgs: [record.value.recordingId],
      orderBy: 'from_order, gap_id',
    );
    for (final row in rows) {
      gap(row, record);
    }
    return rows;
  }

  static Future<Map<String, Object?>?> recovery(
    DatabaseExecutor sql,
    ActivityRecordingRecord record,
  ) async {
    final rows = await sql.query(
      'recording_recovery',
      where: 'recording_id = ?',
      whereArgs: [record.value.recordingId],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    if (row['needed'] != 0 && row['needed'] != 1) throw const FormatException();
    final cursor = row['processed_through'];
    if (cursor != null) {
      final r = record.value;
      if (cursor is! int ||
          cursor < r.recordingStartedAt.microsecondsSinceEpoch ||
          r.lastSampleAt == null ||
          cursor > r.lastSampleAt!.microsecondsSinceEpoch ||
          (r.endedAt != null && cursor > r.endedAt!.microsecondsSinceEpoch)) {
        throw const FormatException();
      }
      // Also reject values outside Dart's representable UTC timestamp range.
      DateTime.fromMicrosecondsSinceEpoch(cursor, isUtc: true);
    }
    return row;
  }

  /// Finish may delete/clamp rows and aggregate all segment IDs. Validate those
  /// identifiers first. This finite lifecycle scan is never used by local repair.
  static Future<void> beforeFinish(
    DatabaseExecutor sql,
    ActivityRecordingRecord record,
  ) async {
    final invalid = await sql.rawQuery(
      '''SELECT 1 FROM route_points
      WHERE recording_id = ? AND (typeof(sample_key) != 'text' OR sample_key = ''
      OR typeof(segment_id) != 'text' OR length(segment_id) != 64
      OR segment_id GLOB '*[^0-9a-f]*') LIMIT 1''',
      [record.value.recordingId],
    );
    if (invalid.isNotEmpty) throw const FormatException();
  }
}
