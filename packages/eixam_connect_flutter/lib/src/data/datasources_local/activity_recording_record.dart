import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../../device/canonical_hardware_id.dart';

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

/// Version-one metadata mapping. No route ingestion or metric calculation.
final class ActivityRecordingRecord {
  const ActivityRecordingRecord(this.owner, this.value);

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
    if (device != null && normalizeCanonicalHardwareId(device) != device) {
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
    // AR2A cannot honestly read route-bearing metadata. AR2B must migrate/extend
    // this mapper and the route reader together, never emit fake empty pages.
    for (final field in [
      'point_count',
      'segment_count',
      'unresolved_gap_count',
      'route_revision',
      'previous_route_revision',
    ]) {
      if (count(field) != 0) throw const FormatException();
    }
    for (final field in [
      'first_sample_at',
      'last_sample_at',
      'distance_meters',
      'route_changed_from',
    ]) {
      if (row[field] != null) throw const FormatException();
    }
    if (quality != ActivityRecordingRouteQuality.unknown ||
        recovery == ActivityRecordingRecoveryState.recovering ||
        input == ActivityRecordingInputState.observing) {
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
      ),
    );
  }

  final ActivityRecordingOwner owner;
  final SdkActivityRecording value;

  ActivityRecordingRecord transition({
    ActivityRecordingPhase? phase,
    DateTime? endedAt,
    String? deviceIdentity,
    ActivityRecordingInputState? inputState,
  }) => ActivityRecordingRecord(
    owner,
    SdkActivityRecording(
      recordingId: value.recordingId,
      activitySessionId: value.activitySessionId,
      activityKey: value.activityKey,
      activitySessionStartedAt: value.activitySessionStartedAt,
      recordingStartedAt: value.recordingStartedAt,
      endedAt: endedAt ?? value.endedAt,
      deviceIdentity: deviceIdentity ?? value.deviceIdentity,
      phase: phase ?? value.phase,
      inputState: inputState ?? value.inputState,
      recoveryState: value.recoveryState,
      routeQuality: value.routeQuality,
      issues: value.issues,
    ),
  );

  Map<String, Object?> encode() => {
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
