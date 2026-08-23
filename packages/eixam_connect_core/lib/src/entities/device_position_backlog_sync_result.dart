/// Semantic outcome of retrieving persistent positions from a connected TAG.
class DevicePositionBacklogSyncResult {
  const DevicePositionBacklogSyncResult({
    required this.completed,
    required this.timedOut,
    required this.partial,
    required this.recoveredCount,
    required this.duplicateCount,
    required this.rejectedCount,
    required this.retentionGapDetected,
  });

  final bool completed;
  final bool timedOut;
  final bool partial;
  final int recoveredCount;
  final int duplicateCount;
  final int rejectedCount;

  /// True only when retained protocol metadata proves requested history loss.
  /// Current protocol version 1 does not provide such proof.
  final bool retentionGapDetected;
}
