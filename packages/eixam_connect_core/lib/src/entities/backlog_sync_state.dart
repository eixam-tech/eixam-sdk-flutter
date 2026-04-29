import '../enums/backlog_sync_phase.dart';

/// Public partner-facing view of the SDK-owned BLE backlog sync lifecycle.
class BacklogSyncState {
  const BacklogSyncState({
    required this.phase,
    this.sessionId,
    this.totalEvents,
    this.confirmedEvents = 0,
    this.nextOffset,
    this.lastError,
    this.lastUpdatedAt,
  });

  const BacklogSyncState.idle({
    this.sessionId,
    this.totalEvents,
    this.confirmedEvents = 0,
    this.nextOffset,
    this.lastError,
    this.lastUpdatedAt,
  }) : phase = BacklogSyncPhase.idle;

  final BacklogSyncPhase phase;
  final int? sessionId;
  final int? totalEvents;
  final int confirmedEvents;
  final int? nextOffset;
  final String? lastError;
  final DateTime? lastUpdatedAt;

  bool get isActive =>
      phase == BacklogSyncPhase.starting || phase == BacklogSyncPhase.syncing;

  bool get isTerminal =>
      phase == BacklogSyncPhase.completed ||
      phase == BacklogSyncPhase.cancelled ||
      phase == BacklogSyncPhase.failed;

  bool get hasError => lastError != null && lastError!.trim().isNotEmpty;

  int? get remainingEvents => totalEvents == null
      ? null
      : (totalEvents! - confirmedEvents).clamp(0, totalEvents!);

  double? get completionFraction {
    final total = totalEvents;
    if (total == null || total <= 0) {
      return null;
    }
    final normalized = confirmedEvents.clamp(0, total);
    return normalized / total;
  }

  BacklogSyncState copyWith({
    BacklogSyncPhase? phase,
    Object? sessionId = _unset,
    Object? totalEvents = _unset,
    int? confirmedEvents,
    Object? nextOffset = _unset,
    Object? lastError = _unset,
    DateTime? lastUpdatedAt,
  }) {
    return BacklogSyncState(
      phase: phase ?? this.phase,
      sessionId:
          identical(sessionId, _unset) ? this.sessionId : sessionId as int?,
      totalEvents: identical(totalEvents, _unset)
          ? this.totalEvents
          : totalEvents as int?,
      confirmedEvents: confirmedEvents ?? this.confirmedEvents,
      nextOffset:
          identical(nextOffset, _unset) ? this.nextOffset : nextOffset as int?,
      lastError:
          identical(lastError, _unset) ? this.lastError : lastError as String?,
      lastUpdatedAt: lastUpdatedAt ?? this.lastUpdatedAt,
    );
  }

  static const Object _unset = Object();
}
