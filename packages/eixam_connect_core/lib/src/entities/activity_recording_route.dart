import '../enums/activity_recording.dart';
import 'eixam_device_position_batch.dart';

/// An accepted, timestamped TAG point. Phone location is never a route source.
///
/// The recorder validates coordinates, timestamps, identity and recording window
/// before constructing points. This model does not ingest or decode samples.
final class SdkActivityRoutePoint {
  SdkActivityRoutePoint({
    required this.stableSampleKey,
    required DateTime sampledAt,
    required this.latitude,
    required this.longitude,
    required this.delivery,
    this.altitudeMeters,
  }) : sampledAt = sampledAt.toUtc();

  /// Opaque sample identity for comparison/deduplication, never host parsing.
  final String stableSampleKey;

  /// Original TAG sample time, never a substituted phone reception timestamp.
  final DateTime sampledAt;
  final double latitude;
  final double longitude;

  /// Real coarse TAG altitude when available; no ascent/descent metric implied.
  final double? altitudeMeters;

  /// First accepted delivery provenance; replay does not create another point.
  final EixamDevicePositionDelivery delivery;
}

/// Canonical continuity group (or page fragment), independent of map rendering.
final class SdkActivityRouteSegment {
  SdkActivityRouteSegment({
    required this.segmentId,
    required List<SdkActivityRoutePoint> points,
  }) : points = List.unmodifiable(points);

  /// Identifies continuation across pages of the same route revision.
  final String segmentId;

  /// Chronologically ordered by the recorder; construction does not sort.
  final List<SdkActivityRoutePoint> points;
}

/// Declared interval of uncertain TAG-route continuity, including intervals
/// before the first point or after the last point.
final class SdkActivityRouteGap {
  SdkActivityRouteGap({
    required this.gapId,
    required DateTime from,
    required this.reason,
    required this.state,
    DateTime? until,
  }) : from = from.toUtc(),
       until = until?.toUtc();

  final String gapId;
  final DateTime from;

  /// Null while the uncertainty interval is still open.
  final DateTime? until;
  final ActivityRecordingGapReason reason;
  final ActivityRecordingGapState state;
}

/// One immutable page of a finite route read at a single consistent revision.
///
/// A logical segment may span pages; identical segment IDs identify continuation.
/// The recorder emits a terminal page even when no points or gaps exist.
/// Page fragments must not be interpreted as new route discontinuities.
final class SdkActivityRoutePage {
  SdkActivityRoutePage({
    required this.recordingId,
    required this.routeRevision,
    required List<SdkActivityRouteSegment> segments,
    required List<SdkActivityRouteGap> gaps,
    required this.isLast,
  }) : segments = List.unmodifiable(segments),
       gaps = List.unmodifiable(gaps);

  final String recordingId;
  final int routeRevision;
  final List<SdkActivityRouteSegment> segments;
  final List<SdkActivityRouteGap> gaps;
  final bool isLast;
}
