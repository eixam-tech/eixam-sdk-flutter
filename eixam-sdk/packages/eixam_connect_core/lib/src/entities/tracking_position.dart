import '../enums/delivery_mode.dart';

class TrackingPosition {
  final double latitude;
  final double longitude;
  final double? altitude;
  final double? accuracy;
  final double? speed;
  final double? heading;
  final DeliveryMode source;
  final DateTime timestamp;

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

  Duration get age => DateTime.now().difference(timestamp);
  bool get isStale => age > const Duration(minutes: 2);
}
