/// Semantic outcome of retrieving persistent positions from a connected TAG.
class DevicePositionBacklogSyncResult {
  const DevicePositionBacklogSyncResult({
    required this.completed,
    required this.timedOut,
    required this.partial,
    required this.recoveredCount,
    required this.duplicateCount,
    required this.retentionGapDetected,
    int? rejectedUntilCount,
    @Deprecated('Use rejectedUntilCount.') int? rejectedCount,
    this.metaTotalEvents,
    this.receivedCount = 0,
    this.endSentEvents,
    this.lastProcessedSampleAt,
  }) : rejectedUntilCount = rejectedUntilCount ?? rejectedCount ?? 0;

  final bool completed;
  final bool timedOut;
  final bool partial;
  final int? metaTotalEvents;
  final int receivedCount;
  final int recoveredCount;
  final int duplicateCount;
  final int rejectedUntilCount;

  @Deprecated('Use rejectedUntilCount.')
  int get rejectedCount => rejectedUntilCount;
  final int? endSentEvents;

  /// Latest original TAG timestamp successfully processed in this D1 session.
  ///
  /// This includes deduplicated records, but excludes records rejected by the
  /// optional upper bound. Callers may retry inclusively from this timestamp.
  final DateTime? lastProcessedSampleAt;

  bool get backlogEmpty => completed && metaTotalEvents == 0;

  /// True only when retained protocol metadata proves requested history loss.
  /// Current protocol version 1 does not provide such proof.
  final bool retentionGapDetected;
}
