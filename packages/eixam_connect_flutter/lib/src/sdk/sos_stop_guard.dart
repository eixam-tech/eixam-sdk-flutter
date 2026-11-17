import '../diagnostics/sdk_release_log.dart';

/// What a path is about to do to the current SOS.
enum SosStopKind {
  /// Write a stop command (0x04 cancel / 0x07 resolve) to the TAG from Dart.
  tagStop,

  /// Ask native to close its TAG cycle (native writes the stop if it still
  /// holds the cycle). F17c item 1: an automated close must name the exact
  /// native cycle ([SosStopRequest.nativeCycleId]); only the user's own action
  /// may target the cycle running now without one.
  nativeCycleClose,

  /// Move the current SOS to cancelled / resolved from a backend event.
  backendTerminal,

  /// Move the current SOS to cancelled / resolved / idle because a REST read
  /// shows no open incident.
  restAbsence,

  /// Replace (or close) the current SOS with the incident a REST read
  /// returned.
  restIncident,
}

/// Why the path believes the evidence is about the current SOS.
enum SosStopBasis {
  /// The user acted on this SOS (app cancel / resolve, TAG notification
  /// action, the prompt's "No, stop the TAG", logout).
  userAction,

  /// A TAG stop already decided for this SOS and still owed (native retries
  /// it until a write succeeded).
  owedStop,

  /// The evidence carries the current SOS's backend incident id.
  exactIncident,

  /// The evidence carries the current SOS's publish timestamp, echoed by the
  /// backend as `occurredAt`.
  exactOccurredAt,

  /// A stop or close that follows a terminal of the current SOS already
  /// decided by an authorized path (this guard, or the user): refused only
  /// when it names a superseded SOS (the current SOS carrying another SOS's
  /// identity).
  authorizedUpstream,

  /// The evidence names no incident (or names it only through an earlier,
  /// non-exact adoption). Valid only while no other SOS of this user can be
  /// confused with the current one: the backend keeps one open SOS per user.
  userScoped,
}

/// One request to the [SosStopGuard]. Identifiers are used for the decision
/// only, never logged.
final class SosStopRequest {
  const SosStopRequest({
    required this.kind,
    required this.basis,
    required this.source,
    this.incidentId,
    this.occurredAt,
    this.currentPublishedAt,
    this.nativeCycleId,
  });

  final SosStopKind kind;
  final SosStopBasis basis;

  /// Fixed code of the calling path, logged on a refusal.
  final String source;

  /// Backend incident id the evidence names.
  final String? incidentId;

  /// Backend `occurredAt` the evidence carries.
  final DateTime? occurredAt;

  /// Publish timestamp of the current SOS (for [SosStopBasis.exactOccurredAt]).
  final DateTime? currentPublishedAt;

  /// F17c item 1 ([SosStopKind.nativeCycleClose]): the native SOS cycle id
  /// the stop is for, as native reported it for this SOS. Never logged.
  final String? nativeCycleId;
}

final class SosStopDecision {
  const SosStopDecision._(this.allowed, this.reason);

  final bool allowed;
  final String reason;
}

/// Evidence about an SOS the TAG closed (or the phone settled locally) whose
/// close the backend has not confirmed, kept so its late events and REST
/// reads are attributed to it and never to a newer SOS.
final class SupersededSosEvidence {
  const SupersededSosEvidence({
    required this.closedAt,
    this.publishedAt,
    this.incidentIds = const <String>[],
  });

  /// When the TAG closed it: every SOS opened after this is newer, so an
  /// `occurredAt` at or before it is never the current SOS's.
  final DateTime closedAt;

  /// Its trigger's publish timestamp (echoed as `occurredAt`), when known.
  final DateTime? publishedAt;

  /// Its backend incident ids, when known.
  final List<String> incidentIds;

  SupersededSosEvidence withIncidentId(String id) => SupersededSosEvidence(
    closedAt: closedAt,
    publishedAt: publishedAt,
    incidentIds: <String>[...incidentIds.where((known) => known != id), id],
  );

  SupersededSosEvidence withoutIncidentId(String id) => SupersededSosEvidence(
    closedAt: closedAt,
    publishedAt: publishedAt,
    incidentIds: incidentIds.where((known) => known != id).toList(),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'closedAt': closedAt.toUtc().toIso8601String(),
    if (publishedAt != null)
      'publishedAt': publishedAt!.toUtc().toIso8601String(),
    'incidentIds': incidentIds,
  };

  static SupersededSosEvidence? tryParse(Object? json) {
    if (json is! Map) {
      return null;
    }
    final closedAt = DateTime.tryParse('${json['closedAt']}')?.toUtc();
    if (closedAt == null) {
      return null;
    }
    final ids = json['incidentIds'];
    return SupersededSosEvidence(
      closedAt: closedAt,
      publishedAt: json['publishedAt'] == null
          ? null
          : DateTime.tryParse('${json['publishedAt']}')?.toUtc(),
      incidentIds: ids is List
          ? ids.whereType<String>().where((id) => id.isNotEmpty).toList()
          : const <String>[],
    );
  }
}

/// F17c review r7 (Roger 17/11/2026): the single decision every SDK path
/// takes before it
/// - writes a stop command (0x04 cancel / 0x07 resolve) to the TAG, from
///   Dart or by asking native to close its cycle, or
/// - moves the current SOS to cancelled / resolved / idle from a backend
///   event or a REST read.
///
/// Allowed only when the evidence is provably the current SOS (its exact
/// backend incident id or its exact publish timestamp echoed as
/// `occurredAt`), when the user acted on this SOS, when the stop is already
/// owed for it, or when no other SOS of this user can be confused with it
/// (one open SOS per user, so user-scoped evidence is the current SOS's).
/// Evidence of a superseded SOS (one the TAG closed while its backend close
/// was still pending) is never the current SOS's. Otherwise the SOS stays
/// active and the refusal is logged: a missed SOS is worse than a duplicate.
///
/// It also holds the attribution state the decision needs (persisted by the
/// repository with its own state). The native stop-with-cycle-id change
/// consults [authorize] as well.
final class SosStopGuard {
  SosStopGuard({void Function()? onChanged}) : _onChanged = onChanged;

  static const int _maxEvidence = 8;

  void Function()? _onChanged;
  final List<SupersededSosEvidence> _superseded = <SupersededSosEvidence>[];
  bool _attributionOpen = false;

  /// Trigger timestamps this phone published (bounded, persisted).
  final List<DateTime> _ownPublished = <DateTime>[];

  /// Incident ids proven to be the current SOS's after they were a
  /// superseded SOS's (merged incident, r7 MEDIUM-1).
  final Set<String> _reassigned = <String>{};

  DateTime? _currentPublishedAt;

  /// Publish timestamp of this phone's trigger of the current SOS (null when
  /// the current SOS is not this phone's own trigger, e.g. another source's
  /// SOS read over REST). Persisted: survives a restart.
  DateTime? get currentPublishedAt => _currentPublishedAt;

  set currentPublishedAt(DateTime? at) {
    final utc = at?.toUtc();
    if (utc == _currentPublishedAt) {
      return;
    }
    _currentPublishedAt = utc;
    _onChanged?.call();
  }

  set onChanged(void Function()? callback) => _onChanged = callback;

  /// A superseded SOS's close has not been attributed to the current SOS
  /// exactly yet: only exact evidence (or the user) may end or identify the
  /// current SOS.
  bool get attributionOpen => _attributionOpen;

  List<SupersededSosEvidence> get superseded =>
      List<SupersededSosEvidence>.unmodifiable(_superseded);

  /// The TAG closed (or the phone settled) an SOS whose backend close is not
  /// confirmed, and a newer SOS may start: attribution opens.
  void recordSuperseded(SupersededSosEvidence evidence) {
    // An id handed to the SOS now superseded belongs to it again.
    _reassigned.removeAll(evidence.incidentIds);
    _superseded.add(evidence);
    while (_superseded.length > _maxEvidence) {
      _superseded.removeAt(0);
    }
    _attributionOpen = true;
    sdkReleaseLog(
      'SOS_OUTBOX_STOP_GUARD_SUPERSEDED_RECORDED '
      'identity=${evidence.incidentIds.isNotEmpty} '
      'published=${evidence.publishedAt != null}',
    );
    _onChanged?.call();
  }

  /// An event or incident proven to belong to a superseded SOS by its
  /// `occurredAt`: its id is that SOS's from now on.
  void learnSupersededIncidentId(String incidentId, DateTime occurredAt) {
    final id = incidentId.trim();
    if (id.isEmpty || isSupersededIncident(id) || _reassigned.contains(id)) {
      return;
    }
    final at = occurredAt.toUtc();
    if (!isSupersededOccurrence(at)) {
      return;
    }
    var index = _superseded.indexWhere((e) => e.publishedAt == at);
    if (index < 0) {
      index = _superseded.indexWhere((e) => !at.isAfter(e.closedAt));
    }
    if (index < 0) {
      return;
    }
    _superseded[index] = _superseded[index].withIncidentId(id);
    _onChanged?.call();
  }

  /// This phone published a trigger with [at] as its timestamp (the
  /// backend echoes it as `occurredAt`). Only these timestamps can be a
  /// superseded SOS's (r7 LOW-4).
  void recordOwnPublish(DateTime at) {
    final utc = at.toUtc();
    if (_ownPublished.contains(utc)) {
      return;
    }
    _ownPublished.add(utc);
    while (_ownPublished.length > _maxEvidence) {
      _ownPublished.removeAt(0);
    }
    _onChanged?.call();
  }

  /// The newest trigger timestamp this phone published at or before [at].
  DateTime? latestOwnPublishAtOrBefore(DateTime at) {
    final utc = at.toUtc();
    DateTime? latest;
    for (final published in _ownPublished) {
      if (!published.isAfter(utc) &&
          (latest == null || published.isAfter(latest))) {
        latest = published;
      }
    }
    return latest;
  }

  /// The newest trigger timestamp this phone published (restored after a
  /// restart).
  DateTime? get latestOwnPublish => _ownPublished.isEmpty
      ? null
      : _ownPublished.reduce((a, b) => a.isAfter(b) ? a : b);

  /// r7 MEDIUM-1: the backend merged the current SOS into a superseded SOS's
  /// still-open incident (that SOS's cancel was rejected or dropped). The
  /// current SOS's exact publish timestamp as `occurredAt` proves the
  /// incident is the current SOS's: its id is no longer a superseded SOS's
  /// (and a late event of that SOS never makes it one again). Returns
  /// whether the id was reassigned.
  bool reassignToCurrent({
    required String? incidentId,
    required DateTime? occurredAt,
    required DateTime? currentPublishedAt,
    required String source,
  }) {
    final id = incidentId?.trim();
    final at = occurredAt?.toUtc();
    final published = currentPublishedAt?.toUtc();
    if (id == null ||
        id.isEmpty ||
        at == null ||
        published == null ||
        at != published ||
        isSupersededOccurrence(at) ||
        !isSupersededIncident(id)) {
      return false;
    }
    for (var i = 0; i < _superseded.length; i++) {
      final evidence = _superseded[i];
      if (evidence.incidentIds.contains(id)) {
        _superseded[i] = evidence.withoutIncidentId(id);
      }
    }
    _reassigned.add(id);
    while (_reassigned.length > _maxEvidence) {
      _reassigned.remove(_reassigned.first);
    }
    sdkReleaseLog(
      'SOS_OUTBOX_STOP_GUARD_MERGED_INCIDENT_REASSIGNED source=$source '
      'reason=exact_current_occurred_at',
    );
    _onChanged?.call();
    return true;
  }

  bool isSupersededIncident(String? incidentId) {
    final id = incidentId?.trim();
    if (id == null || id.isEmpty) {
      return false;
    }
    return _superseded.any((evidence) => evidence.incidentIds.contains(id));
  }

  /// [occurredAt] is a superseded SOS's: its publish timestamp, or a
  /// trigger timestamp this phone published at or before the newest close
  /// (every current SOS started after it). Only this phone's own timestamps:
  /// an SOS from another source (LoRa gateway, a second phone of the
  /// account, another clock) is never taken as a closed one (r7 LOW-4).
  bool isSupersededOccurrence(DateTime? occurredAt) {
    if (occurredAt == null || _superseded.isEmpty) {
      return false;
    }
    final at = occurredAt.toUtc();
    if (_superseded.any((evidence) => evidence.publishedAt == at)) {
      return true;
    }
    final newestClose = _superseded
        .map((evidence) => evidence.closedAt)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    return !at.isAfter(newestClose) && _ownPublished.contains(at);
  }

  bool isSuperseded({String? incidentId, DateTime? occurredAt}) =>
      isSupersededIncident(incidentId) || isSupersededOccurrence(occurredAt);

  /// The current SOS got its exact backend identity (its `processed` with
  /// its own publish timestamp): user-scoped evidence is its own again.
  void closeAttribution(String reason) {
    if (!_attributionOpen) {
      return;
    }
    _attributionOpen = false;
    sdkReleaseLog('SOS_OUTBOX_STOP_GUARD_ATTRIBUTION_CLOSED reason=$reason');
    _onChanged?.call();
  }

  /// Session change: the previous account's evidence is dropped.
  void clear() {
    if (_superseded.isEmpty &&
        !_attributionOpen &&
        _ownPublished.isEmpty &&
        _reassigned.isEmpty &&
        _currentPublishedAt == null) {
      return;
    }
    _superseded.clear();
    _attributionOpen = false;
    _ownPublished.clear();
    _reassigned.clear();
    _currentPublishedAt = null;
    _onChanged?.call();
  }

  SosStopDecision authorize(SosStopRequest request) {
    if (request.basis == SosStopBasis.exactOccurredAt) {
      // r7 MEDIUM-1: the current SOS's exact publish timestamp beats a
      // superseded incident id (merged incident).
      reassignToCurrent(
        incidentId: request.incidentId,
        occurredAt: request.occurredAt,
        currentPublishedAt: request.currentPublishedAt,
        source: request.source,
      );
    }
    final decision = _decide(request);
    if (!decision.allowed) {
      sdkReleaseLog(
        'SOS_OUTBOX_STOP_GUARD_REFUSED kind=${request.kind.name} '
        'basis=${request.basis.name} source=${request.source} '
        'reason=${decision.reason} action=keep_sos_active',
      );
    }
    return decision;
  }

  SosStopDecision _decide(SosStopRequest request) {
    if (request.kind == SosStopKind.nativeCycleClose) {
      // F17c item 1 (Roger 17/11/2026): the user's own action targets the
      // native cycle running now, by definition (the user must always be able
      // to stop what rings in front of them). Every automated close must name
      // the exact native cycle it is for: without it native could apply it to
      // a newer SOS Dart has not seen, so it is never sent.
      if (request.basis == SosStopBasis.userAction) {
        return const SosStopDecision._(true, 'user_action_current_cycle');
      }
      final id = request.nativeCycleId?.trim();
      if (id == null || id.isEmpty) {
        return const SosStopDecision._(false, 'unknown_native_cycle');
      }
    }
    switch (request.basis) {
      case SosStopBasis.userAction:
        return const SosStopDecision._(true, 'user_action');
      case SosStopBasis.owedStop:
        return const SosStopDecision._(true, 'owed_stop');
      case SosStopBasis.exactIncident:
      case SosStopBasis.exactOccurredAt:
      case SosStopBasis.authorizedUpstream:
      case SosStopBasis.userScoped:
        break;
    }
    if (isSupersededIncident(request.incidentId)) {
      return const SosStopDecision._(false, 'superseded_incident');
    }
    if (isSupersededOccurrence(request.occurredAt)) {
      return const SosStopDecision._(false, 'superseded_occurrence');
    }
    switch (request.basis) {
      case SosStopBasis.exactIncident:
        final id = request.incidentId?.trim();
        return id == null || id.isEmpty
            ? const SosStopDecision._(false, 'no_incident_identity')
            : const SosStopDecision._(true, 'exact_incident');
      case SosStopBasis.exactOccurredAt:
        final at = request.occurredAt?.toUtc();
        final published = request.currentPublishedAt?.toUtc();
        return at != null && published != null && at == published
            ? const SosStopDecision._(true, 'exact_occurred_at')
            : const SosStopDecision._(false, 'occurred_at_mismatch');
      case SosStopBasis.authorizedUpstream:
        return const SosStopDecision._(true, 'authorized_upstream');
      case SosStopBasis.userScoped:
        return _attributionOpen
            ? const SosStopDecision._(false, 'attribution_open')
            : const SosStopDecision._(true, 'single_user_sos');
      case SosStopBasis.userAction:
      case SosStopBasis.owedStop:
        return const SosStopDecision._(true, 'user_action');
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'attributionOpen': _attributionOpen,
    'superseded': _superseded.map((evidence) => evidence.toJson()).toList(),
    'ownPublished': _ownPublished
        .map((at) => at.toUtc().toIso8601String())
        .toList(),
    'reassigned': _reassigned.toList(),
    if (_currentPublishedAt != null)
      'currentPublishedAt': _currentPublishedAt!.toIso8601String(),
  };

  void restoreFromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return;
    }
    final raw = json['superseded'];
    _superseded
      ..clear()
      ..addAll(
        (raw is List ? raw : const <Object>[])
            .map(SupersededSosEvidence.tryParse)
            .whereType<SupersededSosEvidence>(),
      );
    _attributionOpen = json['attributionOpen'] == true;
    final own = json['ownPublished'];
    _ownPublished
      ..clear()
      ..addAll(
        (own is List ? own : const <Object>[])
            .map((raw) => DateTime.tryParse('$raw')?.toUtc())
            .whereType<DateTime>(),
      );
    _currentPublishedAt = json['currentPublishedAt'] == null
        ? null
        : DateTime.tryParse('${json['currentPublishedAt']}')?.toUtc();
    final reassigned = json['reassigned'];
    _reassigned
      ..clear()
      ..addAll(
        (reassigned is List ? reassigned : const <Object>[])
            .whereType<String>()
            .where((id) => id.isNotEmpty),
      );
  }
}
