import 'package:eixam_connect_core/eixam_connect_core.dart';

TrackingPosition buildTrackingPosition({
  double latitude = 41.3874,
  double longitude = 2.1686,
  DateTime? timestamp,
  DeliveryMode source = DeliveryMode.unknown,
}) {
  return TrackingPosition(
    latitude: latitude,
    longitude: longitude,
    timestamp: timestamp ?? DateTime.utc(2026, 1, 1, 12),
    source: source,
  );
}
