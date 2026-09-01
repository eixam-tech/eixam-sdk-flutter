import '../enums/delivery_mode.dart';
import '../geo/eixam_geo_coordinates.dart';

class TrackingPosition {
  const TrackingPosition({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.altitude,
    this.accuracy,
    this.speed,
    this.heading,
    this.source = DeliveryMode.unknown,
  });
  final double latitude;
  final double longitude;
  final double? altitude;
  final double? accuracy;
  final double? speed;
  final double? heading;
  final DeliveryMode source;
  final DateTime timestamp;

  Duration get age => DateTime.now().difference(timestamp);
  bool get isStale => age > const Duration(minutes: 2);
  bool get hasValidFix => EixamGeoCoordinates.isValidFix(latitude, longitude);
}
