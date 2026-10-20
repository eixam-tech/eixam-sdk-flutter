import 'activity_recording.dart';

/// Immutable, metadata-only page of local, same-owner finished recordings.
/// Nullable distance and unknown/partial route quality preserve stored meaning.
final class SdkActivityRecordingHistoryPage {
  SdkActivityRecordingHistoryPage({
    required List<SdkActivityRecording> items,
    this.nextCursor,
  }) : items = List.unmodifiable(items);

  final List<SdkActivityRecording> items;

  /// Opaque continuation token; null for terminal and empty history.
  /// Consumers must not construct, parse or reuse it across owner scopes.
  final String? nextCursor;

  bool get hasMore => nextCursor != null;
}
