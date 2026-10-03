import '../enums/device_battery_level.dart';

class SdkDeviceBatterySnapshot {
  const SdkDeviceBatterySnapshot({required this.rawValue, required this.range});

  factory SdkDeviceBatterySnapshot.fromLevel(DeviceBatteryLevel level) {
    return SdkDeviceBatterySnapshot(
      rawValue: level.protocolValue,
      range: level.name,
    );
  }

  factory SdkDeviceBatterySnapshot.fromRawValue(num rawValue) {
    final normalized = rawValue.round().clamp(0, 3);
    final level =
        DeviceBatteryLevel.fromProtocolValue(normalized) ??
        DeviceBatteryLevel.critical;
    return SdkDeviceBatterySnapshot(rawValue: normalized, range: level.name);
  }

  final int rawValue;
  final String range;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{'rawValue': rawValue, 'range': range};
  }
}

/// Phone radio sample for the coverage grid. CamelCase SDK ingest.
class SdkRadioSnapshot {
  const SdkRadioSnapshot({
    required this.generation,
    this.fiveGMode,
    this.connected,
  });

  final String generation;
  final String? fiveGMode;
  final bool? connected;

  Map<String, dynamic> toJson() {
    final mode = generation == '5g' ? _acceptedFiveGMode(fiveGMode) : null;
    return <String, dynamic>{
      'generation': generation,
      'fiveGMode': ?mode,
      'connected': ?connected,
    };
  }

  static String? _acceptedFiveGMode(String? mode) {
    switch (mode) {
      case 'sa':
      case 'nsa':
        return mode;
      default:
        return null;
    }
  }
}

/// Drops a missing, non-finite, or negative horizontal accuracy.
/// A coarser-than-50 m value is still sent. The API skips only the grid write.
double? finiteHorizontalAccuracyMeters(double? meters) {
  if (meters == null || !meters.isFinite || meters < 0) {
    return null;
  }
  return meters;
}

class SdkCoverageSnapshot {
  const SdkCoverageSnapshot({
    required this.signalStrength,
    required this.networkType,
    required this.isConnected,
  });

  final int signalStrength;
  final String networkType;
  final bool isConnected;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'signalStrength': signalStrength,
      'networkType': networkType,
      'isConnected': isConnected,
    };
  }
}

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
    this.hardwareId,
    this.identitySource,
    this.deviceBattery,
    this.deviceBatterySnapshot,
    this.deviceCoverage,
    this.deviceCoverageSnapshot,
    this.mobileBattery,
    this.mobileCoverage,
    this.mobileCoverageSnapshot,
    this.horizontalAccuracyMeters,
    this.radio,
    this.phoneRadioSampled = false,
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
  final String? hardwareId;
  final String? identitySource;
  final double? deviceBattery;
  final SdkDeviceBatterySnapshot? deviceBatterySnapshot;
  final int? deviceCoverage;
  final SdkCoverageSnapshot? deviceCoverageSnapshot;
  final double? mobileBattery;
  final int? mobileCoverage;
  final SdkCoverageSnapshot? mobileCoverageSnapshot;
  final double? horizontalAccuracyMeters;
  final SdkRadioSnapshot? radio;

  /// True when a native queue already snapshotted the phone radio for this fix.
  /// Not sent on the wire. Stops a later flush from reading a different network.
  final bool phoneRadioSampled;

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
      if (aggSpreadingFactor != null) 'aggSpreadingFactor': aggSpreadingFactor,
      if (_hasText(eventId)) 'eventId': eventId!.trim(),
      if (_hasText(userId)) 'userId': userId!.trim(),
      if (_hasText(deviceId)) 'deviceId': deviceId!.trim(),
      if (_hasText(hardwareId)) 'hardwareId': hardwareId!.trim(),
      if (_hasText(identitySource)) 'identitySource': identitySource!.trim(),
      if (_resolvedDeviceBattery != null)
        'deviceBattery': _resolvedDeviceBattery!.toJson(),
      if (_resolvedDeviceCoverage != null)
        'deviceCoverage': _resolvedDeviceCoverage!.toJson(),
      if (mobileBattery != null)
        'mobileBattery': mobileBattery!.round().clamp(0, 100),
      if (_resolvedMobileCoverage != null)
        'mobileCoverage': _resolvedMobileCoverage!.toJson(),
      if (_wireHorizontalAccuracyMeters != null)
        'horizontalAccuracyMeters': _wireHorizontalAccuracyMeters,
      if (radio != null) 'radio': radio!.toJson(),
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
    Object? hardwareId = _unset,
    Object? identitySource = _unset,
    Object? deviceBattery = _unset,
    Object? deviceBatterySnapshot = _unset,
    Object? deviceCoverage = _unset,
    Object? deviceCoverageSnapshot = _unset,
    Object? mobileBattery = _unset,
    Object? mobileCoverage = _unset,
    Object? mobileCoverageSnapshot = _unset,
    Object? horizontalAccuracyMeters = _unset,
    Object? radio = _unset,
    bool? phoneRadioSampled,
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
      deviceId: identical(deviceId, _unset)
          ? this.deviceId
          : deviceId as String?,
      hardwareId: identical(hardwareId, _unset)
          ? this.hardwareId
          : hardwareId as String?,
      identitySource: identical(identitySource, _unset)
          ? this.identitySource
          : identitySource as String?,
      deviceBattery: identical(deviceBattery, _unset)
          ? this.deviceBattery
          : deviceBattery as double?,
      deviceBatterySnapshot: identical(deviceBatterySnapshot, _unset)
          ? this.deviceBatterySnapshot
          : deviceBatterySnapshot as SdkDeviceBatterySnapshot?,
      deviceCoverage: identical(deviceCoverage, _unset)
          ? this.deviceCoverage
          : deviceCoverage as int?,
      deviceCoverageSnapshot: identical(deviceCoverageSnapshot, _unset)
          ? this.deviceCoverageSnapshot
          : deviceCoverageSnapshot as SdkCoverageSnapshot?,
      mobileBattery: identical(mobileBattery, _unset)
          ? this.mobileBattery
          : mobileBattery as double?,
      mobileCoverage: identical(mobileCoverage, _unset)
          ? this.mobileCoverage
          : mobileCoverage as int?,
      mobileCoverageSnapshot: identical(mobileCoverageSnapshot, _unset)
          ? this.mobileCoverageSnapshot
          : mobileCoverageSnapshot as SdkCoverageSnapshot?,
      horizontalAccuracyMeters: identical(horizontalAccuracyMeters, _unset)
          ? this.horizontalAccuracyMeters
          : horizontalAccuracyMeters as double?,
      radio: identical(radio, _unset) ? this.radio : radio as SdkRadioSnapshot?,
      phoneRadioSampled: phoneRadioSampled ?? this.phoneRadioSampled,
    );
  }

  SdkDeviceBatterySnapshot? get _resolvedDeviceBattery {
    final snapshot = deviceBatterySnapshot;
    if (snapshot != null) {
      return snapshot;
    }
    final raw = deviceBattery;
    if (raw == null || !raw.isFinite) {
      return null;
    }
    return SdkDeviceBatterySnapshot.fromRawValue(raw);
  }

  SdkCoverageSnapshot? get _resolvedDeviceCoverage {
    final snapshot = deviceCoverageSnapshot;
    if (snapshot != null) {
      return snapshot;
    }
    final signalStrength = deviceCoverage;
    if (signalStrength == null) {
      return null;
    }
    return SdkCoverageSnapshot(
      signalStrength: signalStrength,
      networkType: 'ble',
      isConnected: true,
    );
  }

  SdkCoverageSnapshot? get _resolvedMobileCoverage {
    final snapshot = mobileCoverageSnapshot;
    if (snapshot != null) {
      return snapshot;
    }
    final signalStrength = mobileCoverage;
    if (signalStrength == null) {
      return null;
    }
    return SdkCoverageSnapshot(
      signalStrength: signalStrength,
      networkType: 'mobile',
      isConnected: true,
    );
  }

  double? get _wireHorizontalAccuracyMeters =>
      finiteHorizontalAccuracyMeters(horizontalAccuracyMeters);

  static bool _hasText(String? value) =>
      value != null && value.trim().isNotEmpty;

  static const Object _unset = Object();
}
