class SdkTelemetryPayload {
  const SdkTelemetryPayload({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.altitude,
    this.userId,
    this.deviceId,
    this.deviceBattery,
    this.deviceCoverage,
    this.mobileBattery,
    this.mobileCoverage,
  });

  final DateTime timestamp;
  final double latitude;
  final double longitude;
  final double altitude;
  final String? userId;
  final String? deviceId;
  final double? deviceBattery;
  final int? deviceCoverage;
  final double? mobileBattery;
  final int? mobileCoverage;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'timestamp': timestamp.toUtc().toIso8601String(),
      'latitude': latitude,
      'longitude': longitude,
      'altitude': altitude,
      if (_hasText(userId)) 'userId': userId!.trim(),
      if (_hasText(deviceId)) 'deviceId': deviceId!.trim(),
      if (deviceBattery != null) 'deviceBattery': deviceBattery,
      if (deviceCoverage != null) 'deviceCoverage': deviceCoverage,
      if (mobileBattery != null) 'mobileBattery': mobileBattery,
      if (mobileCoverage != null) 'mobileCoverage': mobileCoverage,
    };
  }

  SdkTelemetryPayload copyWith({
    DateTime? timestamp,
    double? latitude,
    double? longitude,
    double? altitude,
    Object? userId = _unset,
    Object? deviceId = _unset,
    Object? deviceBattery = _unset,
    Object? deviceCoverage = _unset,
    Object? mobileBattery = _unset,
    Object? mobileCoverage = _unset,
  }) {
    return SdkTelemetryPayload(
      timestamp: timestamp ?? this.timestamp,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      altitude: altitude ?? this.altitude,
      userId: identical(userId, _unset) ? this.userId : userId as String?,
      deviceId:
          identical(deviceId, _unset) ? this.deviceId : deviceId as String?,
      deviceBattery: identical(deviceBattery, _unset)
          ? this.deviceBattery
          : deviceBattery as double?,
      deviceCoverage: identical(deviceCoverage, _unset)
          ? this.deviceCoverage
          : deviceCoverage as int?,
      mobileBattery: identical(mobileBattery, _unset)
          ? this.mobileBattery
          : mobileBattery as double?,
      mobileCoverage: identical(mobileCoverage, _unset)
          ? this.mobileCoverage
          : mobileCoverage as int?,
    );
  }

  static bool _hasText(String? value) =>
      value != null && value.trim().isNotEmpty;

  static const Object _unset = Object();
}
