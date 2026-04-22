class SdkTelemetryPayload {
  const SdkTelemetryPayload({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.altitude,
    this.kind,
    this.nodeId,
    this.clusterId,
    this.aggId,
    this.score,
    this.memberCount,
    this.aggSpreadingFactor,
    this.eventId,
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
  final String? kind;
  final int? nodeId;
  final int? clusterId;
  final int? aggId;
  final int? score;
  final int? memberCount;
  final int? aggSpreadingFactor;
  final String? eventId;
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
      if (_hasText(kind)) 'kind': kind!.trim(),
      if (nodeId != null) 'nodeId': nodeId,
      if (clusterId != null) 'clusterId': clusterId,
      if (aggId != null) 'aggId': aggId,
      if (score != null) 'score': score,
      if (memberCount != null) 'memberCount': memberCount,
      if (aggSpreadingFactor != null)
        'aggSpreadingFactor': aggSpreadingFactor,
      if (_hasText(eventId)) 'eventId': eventId!.trim(),
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
    Object? kind = _unset,
    Object? nodeId = _unset,
    Object? clusterId = _unset,
    Object? aggId = _unset,
    Object? score = _unset,
    Object? memberCount = _unset,
    Object? aggSpreadingFactor = _unset,
    Object? eventId = _unset,
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
      kind: identical(kind, _unset) ? this.kind : kind as String?,
      nodeId: identical(nodeId, _unset) ? this.nodeId : nodeId as int?,
      clusterId: identical(clusterId, _unset)
          ? this.clusterId
          : clusterId as int?,
      aggId: identical(aggId, _unset) ? this.aggId : aggId as int?,
      score: identical(score, _unset) ? this.score : score as int?,
      memberCount: identical(memberCount, _unset)
          ? this.memberCount
          : memberCount as int?,
      aggSpreadingFactor: identical(aggSpreadingFactor, _unset)
          ? this.aggSpreadingFactor
          : aggSpreadingFactor as int?,
      eventId: identical(eventId, _unset) ? this.eventId : eventId as String?,
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
