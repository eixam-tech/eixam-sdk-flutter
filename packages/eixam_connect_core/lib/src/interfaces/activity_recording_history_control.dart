import '../entities/activity_recording_history_page.dart';

/// Optional, owner-scoped history of locally stored finished recordings.
/// Discover with `sdk is ActivityRecordingHistoryControl`.
///
/// Results contain authoritative summary metadata only, without route payloads,
/// backend/cloud synchronization or age-based retention. Soft-deleted recordings
/// are excluded; optional deletion uses ActivityRecordingDeleteControl. Active and
/// finalizing recordings remain available through ActivityRecordingControl.
abstract interface class ActivityRecordingHistoryControl {
  /// Orders by fixed recording cutoff (`endedAt`) descending, then recording ID
  /// descending. Unknown/partial quality and nullable distance remain unchanged.
  ///
  /// [limit] defaults to 20 and must be 1..100, otherwise throws RangeError.
  /// [cursor] must be an opaque nextCursor returned for the current owner;
  /// malformed/foreign cursors fail with E_RECORDING_INVALID_CURSOR. Unreadable
  /// or inconsistent metadata fails with E_RECORDING_RESTORE_FAILED, never a
  /// partial page or fabricated absence. Listing does not certify route integrity.
  ///
  /// Pagination continues strictly below the previous page's last ordering key;
  /// it is not a snapshot across requests. A new head item needs a page-one
  /// refresh. A delayed finish with an older cutoff may appear on a later page.
  /// Logout/account cleanup follows existing recording privacy semantics.
  Future<SdkActivityRecordingHistoryPage> listFinishedActivityRecordings({
    int limit = 20,
    String? cursor,
  });
}
