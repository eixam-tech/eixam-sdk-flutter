import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../../activity/activity_recording_source_identity.dart';

/// Private identity provenance. Never persists credentials or signing hashes.
final class ActivityRecordingOwner {
  const ActivityRecordingOwner(
    this.scope,
    this.sdkUserId,
    this.canonicalUserId,
  );

  factory ActivityRecordingOwner.forIdentity(
    String backend,
    EixamSession user,
  ) {
    String? present(String? value) => value?.isNotEmpty == true ? value : null;
    return ActivityRecordingOwner(
      sha256
          .convert(
            utf8.encode(
              jsonEncode([
                backend.replaceFirst(RegExp(r'/+$'), ''),
                user.appId,
                user.externalUserId,
              ]),
            ),
          )
          .toString(),
      present(user.sdkUserId),
      present(user.canonicalExternalUserId),
    );
  }

  final String scope;
  final String? sdkUserId;
  final String? canonicalUserId;

  bool conflicts(ActivityRecordingOwner other) {
    bool differs(String? a, String? b) => a != null && b != null && a != b;
    return differs(sdkUserId, other.sdkUserId) ||
        differs(canonicalUserId, other.canonicalUserId);
  }
}

/// Private metadata mapping; validates summary shape without loading route arrays.
final class ActivityRecordingRecord {
  const ActivityRecordingRecord(
    this.owner,
    this.value, {
    this.finalizationStartedAt,
    this.finalizationDeadlineAt,
    this.isDeleted = false,
  });

  factory ActivityRecordingRecord.decode(Map<String, Object?> row) {
    String text(String key) {
      final value = row[key];
      if (value is! String || value.isEmpty) throw const FormatException();
      return value;
    }

    String? optionalText(String key) => row[key] == null ? null : text(key);
    DateTime time(String key) {
      final raw = text(key);
      final parsed = DateTime.parse(raw);
      if (!parsed.isUtc || parsed.toIso8601String() != raw) {
        throw const FormatException();
      }
      return parsed;
    }

    T choice<T extends Enum>(String key, List<T> values) =>
        values.singleWhere((value) => value.name == text(key));
    int count(String key) {
      final value = row[key];
      if (value is! int || value < 0) throw const FormatException();
      return value;
    }

    final id = text('recording_id');
    final scope = text('owner_scope');
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(scope)) {
      throw const FormatException();
    }
    final key = text('activity_key');
    SdkActivitySession.validateActivityKey(key);
    final activityStart = time('session_started_at');
    final start = time('recording_started_at');
    final end = row['ended_at'] == null ? null : time('ended_at');
    final phase = choice('phase', ActivityRecordingPhase.values);
    // Legacy migration backfill decodes rows before the additive v6 column.
    final deleted = row.containsKey('is_deleted') ? row['is_deleted'] : 0;
    if ((deleted != 0 && deleted != 1) ||
        (deleted == 1 && phase != ActivityRecordingPhase.finished)) {
      throw const FormatException();
    }
    final input = choice('input_state', ActivityRecordingInputState.values);
    final recovery = choice(
      'recovery_state',
      ActivityRecordingRecoveryState.values,
    );
    final quality = choice(
      'route_quality',
      ActivityRecordingRouteQuality.values,
    );
    final device = optionalText('device_identity');
    if (device != null &&
        ActivityRecordingSourceIdentity.normalize(device) != device) {
      throw const FormatException();
    }
    final issuesJson = jsonDecode(text('issues'));
    if (issuesJson is! List || issuesJson.any((v) => v is! String)) {
      throw const FormatException();
    }
    final issues = issuesJson
        .map(
          (name) =>
              ActivityRecordingIssue.values.singleWhere((v) => v.name == name),
        )
        .toSet();
    if (issues.length != issuesJson.length ||
        start.isBefore(activityStart) ||
        ((phase == ActivityRecordingPhase.active) != (end == null)) ||
        (end != null && end.isBefore(start)) ||
        ((device == null) != (input == ActivityRecordingInputState.unbound))) {
      throw const FormatException();
    }
    final points = count('point_count');
    final segments = count('segment_count');
    final gaps = count('unresolved_gap_count');
    final revision = count('route_revision');
    final previous = count('previous_route_revision');
    final first = row['first_sample_at'] == null
        ? null
        : time('first_sample_at');
    final last = row['last_sample_at'] == null ? null : time('last_sample_at');
    final changed = row['route_changed_from'] == null
        ? null
        : time('route_changed_from');
    final rawDistance = row['distance_meters'];
    final distance = rawDistance is num ? rawDistance.toDouble() : null;
    if (row.containsKey('distance_edge_count')) {
      final edges = count('distance_edge_count');
      if (edges > (points == 0 ? 0 : points - 1) ||
          ((edges == 0) != (distance == null))) {
        throw const FormatException();
      }
    }
    if ((rawDistance != null &&
            (distance == null || !distance.isFinite || distance < 0)) ||
        (points == 0
            ? first != null || last != null || segments != 0 || distance != null
            : device == null ||
                  first == null ||
                  last == null ||
                  segments < 1 ||
                  segments > points) ||
        (first != null && (first.isBefore(start) || last!.isBefore(first))) ||
        (last != null && end != null && last.isAfter(end)) ||
        (distance != null && points < 2) ||
        (revision == 0
            ? previous != 0 || changed != null || points != 0 || gaps != 0
            : previous != revision - 1 || changed == null) ||
        (changed != null && changed.isBefore(start)) ||
        (gaps == 0
            ? quality != ActivityRecordingRouteQuality.unknown
            : quality != ActivityRecordingRouteQuality.partial)) {
      throw const FormatException();
    }
    final finishStart = row['finalization_started_at'] == null
        ? null
        : time('finalization_started_at');
    final finishDeadline = row['finalization_deadline_at'] == null
        ? null
        : time('finalization_deadline_at');
    if ((finishStart == null) != (finishDeadline == null) ||
        (finishStart != null &&
            (phase == ActivityRecordingPhase.active ||
                finishDeadline!.difference(finishStart) !=
                    const Duration(seconds: 5)))) {
      throw const FormatException();
    }
    return ActivityRecordingRecord(
      ActivityRecordingOwner(
        scope,
        optionalText('sdk_user_id'),
        optionalText('canonical_user_id'),
      ),
      SdkActivityRecording(
        recordingId: id,
        activitySessionId: text('activity_session_id'),
        activityKey: key,
        activitySessionStartedAt: activityStart,
        recordingStartedAt: start,
        endedAt: end,
        deviceIdentity: device,
        phase: phase,
        inputState: input,
        recoveryState: recovery,
        routeQuality: quality,
        issues: issues,
        pointCount: points,
        segmentCount: segments,
        unresolvedGapCount: gaps,
        firstSampleAt: first,
        lastSampleAt: last,
        recordedDistanceMeters: distance,
        routeRevision: revision,
        previousRouteRevision: previous,
        routeChangedFrom: changed,
      ),
      finalizationStartedAt: finishStart,
      finalizationDeadlineAt: finishDeadline,
      isDeleted: deleted == 1,
    );
  }

  final ActivityRecordingOwner owner;
  final SdkActivityRecording value;
  final DateTime? finalizationStartedAt;
  final DateTime? finalizationDeadlineAt;
  final bool isDeleted;

  ActivityRecordingRecord transition({
    bool? isDeleted,
    ActivityRecordingPhase? phase,
    DateTime? finalizationStartedAt,
    DateTime? finalizationDeadlineAt,
    DateTime? endedAt,
    String? deviceIdentity,
    ActivityRecordingInputState? inputState,
    ActivityRecordingRecoveryState? recoveryState,
    Set<ActivityRecordingIssue>? issues,
  }) => ActivityRecordingRecord.decode({
    ...encode(),
    if (isDeleted != null) 'is_deleted': isDeleted ? 1 : 0,
    if (finalizationStartedAt != null)
      'finalization_started_at': finalizationStartedAt
          .toUtc()
          .toIso8601String(),
    if (finalizationDeadlineAt != null)
      'finalization_deadline_at': finalizationDeadlineAt
          .toUtc()
          .toIso8601String(),
    if (phase != null) 'phase': phase.name,
    if (endedAt != null) 'ended_at': endedAt.toUtc().toIso8601String(),
    if (deviceIdentity != null) 'device_identity': deviceIdentity,
    if (inputState != null) 'input_state': inputState.name,
    if (recoveryState != null) 'recovery_state': recoveryState.name,
    if (issues != null)
      'issues': jsonEncode(issues.map((e) => e.name).toList()..sort()),
  });

  Map<String, Object?> encode() => {
    'is_deleted': isDeleted ? 1 : 0,
    if (finalizationStartedAt != null)
      'finalization_started_at': finalizationStartedAt!.toIso8601String(),
    if (finalizationDeadlineAt != null)
      'finalization_deadline_at': finalizationDeadlineAt!.toIso8601String(),
    'recording_id': value.recordingId,
    'owner_scope': owner.scope,
    'sdk_user_id': owner.sdkUserId,
    'canonical_user_id': owner.canonicalUserId,
    'activity_session_id': value.activitySessionId,
    'activity_key': value.activityKey,
    'session_started_at': value.activitySessionStartedAt.toIso8601String(),
    'recording_started_at': value.recordingStartedAt.toIso8601String(),
    'ended_at': value.endedAt?.toIso8601String(),
    'device_identity': value.deviceIdentity,
    'phase': value.phase.name,
    'input_state': value.inputState.name,
    'recovery_state': value.recoveryState.name,
    'route_quality': value.routeQuality.name,
    'issues': jsonEncode(value.issues.map((v) => v.name).toList()..sort()),
    'point_count': value.pointCount,
    'segment_count': value.segmentCount,
    'unresolved_gap_count': value.unresolvedGapCount,
    'first_sample_at': value.firstSampleAt?.toIso8601String(),
    'last_sample_at': value.lastSampleAt?.toIso8601String(),
    'distance_meters': value.recordedDistanceMeters,
    'route_revision': value.routeRevision,
    'previous_route_revision': value.previousRouteRevision,
    'route_changed_from': value.routeChangedFrom?.toIso8601String(),
  };
}
