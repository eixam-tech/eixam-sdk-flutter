import '../enums/delivery_mode.dart';
import 'tracking_position.dart';

enum SdkLocationSource {
  connectedDevice,
  phone,
  backendSnapshot,
  remoteRelayDevice,
  cachedFallback,
  unknown,
}

class SdkResolvedLocation {
  const SdkResolvedLocation({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    required this.source,
    required this.isFresh,
    required this.isValid,
    required bool authoritativeForBackend,
    this.accuracyMeters,
    this.altitudeMeters,
    this.deviceId,
    this.hardwareId,
    this.nodeId,
    this.relayNodeId,
    this.freshness,
  }) : authoritativeForBackend = source == SdkLocationSource.cachedFallback ||
                source == SdkLocationSource.backendSnapshot
            ? false
            : authoritativeForBackend;

  factory SdkResolvedLocation.fromTrackingPosition({
    required TrackingPosition position,
    required SdkLocationSource source,
    bool isFresh = true,
    bool? authoritativeForBackend,
    String? deviceId,
    String? hardwareId,
    int? nodeId,
    int? relayNodeId,
    Duration? freshness,
  }) {
    return SdkResolvedLocation(
      latitude: position.latitude,
      longitude: position.longitude,
      altitudeMeters: position.altitude,
      accuracyMeters: position.accuracy,
      timestamp: position.timestamp,
      source: source,
      deviceId: deviceId,
      hardwareId: hardwareId,
      nodeId: nodeId,
      relayNodeId: relayNodeId,
      freshness: freshness,
      isFresh: isFresh,
      isValid: _isValidCoordinate(position.latitude, position.longitude),
      authoritativeForBackend: _coerceAuthorityForSource(
        source,
        authoritativeForBackend ?? _defaultAuthorityForSource(source),
      ),
    );
  }

  factory SdkResolvedLocation.fromPhoneTrackingPosition({
    required TrackingPosition position,
    bool isFresh = true,
    Duration? freshness,
  }) {
    return SdkResolvedLocation.fromTrackingPosition(
      position: position,
      source: SdkLocationSource.phone,
      isFresh: isFresh,
      freshness: freshness,
      authoritativeForBackend: true,
    );
  }

  factory SdkResolvedLocation.backendSnapshot({
    required TrackingPosition position,
    bool isFresh = true,
    Duration? freshness,
  }) {
    return SdkResolvedLocation.fromTrackingPosition(
      position: position,
      source: SdkLocationSource.backendSnapshot,
      isFresh: isFresh,
      freshness: freshness,
      authoritativeForBackend: false,
    );
  }

  factory SdkResolvedLocation.cachedFallback({
    required TrackingPosition position,
    bool isFresh = false,
    Duration? freshness,
  }) {
    return SdkResolvedLocation.fromTrackingPosition(
      position: position,
      source: SdkLocationSource.cachedFallback,
      isFresh: isFresh,
      freshness: freshness,
      authoritativeForBackend: false,
    );
  }

  factory SdkResolvedLocation.connectedDevice({
    required double latitude,
    required double longitude,
    required DateTime timestamp,
    double? accuracyMeters,
    double? altitudeMeters,
    String? deviceId,
    String? hardwareId,
    int? nodeId,
    Duration? freshness,
    bool isFresh = true,
  }) {
    return SdkResolvedLocation(
      latitude: latitude,
      longitude: longitude,
      timestamp: timestamp,
      accuracyMeters: accuracyMeters,
      altitudeMeters: altitudeMeters,
      source: SdkLocationSource.connectedDevice,
      deviceId: deviceId,
      hardwareId: hardwareId,
      nodeId: nodeId,
      freshness: freshness,
      isFresh: isFresh,
      isValid: _isValidCoordinate(latitude, longitude),
      authoritativeForBackend: true,
    );
  }

  factory SdkResolvedLocation.remoteRelayDevice({
    required double latitude,
    required double longitude,
    required DateTime timestamp,
    double? accuracyMeters,
    double? altitudeMeters,
    String? deviceId,
    String? hardwareId,
    int? nodeId,
    int? relayNodeId,
    Duration? freshness,
    bool isFresh = true,
  }) {
    return SdkResolvedLocation(
      latitude: latitude,
      longitude: longitude,
      timestamp: timestamp,
      accuracyMeters: accuracyMeters,
      altitudeMeters: altitudeMeters,
      source: SdkLocationSource.remoteRelayDevice,
      deviceId: deviceId,
      hardwareId: hardwareId,
      nodeId: nodeId,
      relayNodeId: relayNodeId,
      freshness: freshness,
      isFresh: isFresh,
      isValid: _isValidCoordinate(latitude, longitude),
      authoritativeForBackend: true,
    );
  }

  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final double? accuracyMeters;
  final double? altitudeMeters;
  final SdkLocationSource source;
  final String? deviceId;
  final String? hardwareId;
  final int? nodeId;
  final int? relayNodeId;
  final Duration? freshness;
  final bool isFresh;
  final bool isValid;
  final bool authoritativeForBackend;

  TrackingPosition toTrackingPosition() {
    return TrackingPosition(
      latitude: latitude,
      longitude: longitude,
      altitude: altitudeMeters,
      accuracy: accuracyMeters,
      timestamp: timestamp,
      source: switch (source) {
        SdkLocationSource.phone => DeliveryMode.mobile,
        SdkLocationSource.connectedDevice ||
        SdkLocationSource.remoteRelayDevice =>
          DeliveryMode.mesh,
        _ => DeliveryMode.unknown,
      },
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'latitude': latitude,
      'longitude': longitude,
      'timestamp': timestamp.toUtc().toIso8601String(),
      if (accuracyMeters != null) 'accuracyMeters': accuracyMeters,
      if (altitudeMeters != null) 'altitudeMeters': altitudeMeters,
      'source': source.name,
      if (deviceId != null && deviceId!.trim().isNotEmpty)
        'deviceId': deviceId!.trim(),
      if (hardwareId != null && hardwareId!.trim().isNotEmpty)
        'hardwareId': hardwareId!.trim(),
      if (nodeId != null) 'nodeId': nodeId,
      if (relayNodeId != null) 'relayNodeId': relayNodeId,
      if (freshness != null) 'freshnessMs': freshness!.inMilliseconds,
      'isFresh': isFresh,
      'isValid': isValid,
      'authoritativeForBackend': authoritativeForBackend,
    };
  }

  SdkResolvedLocation copyWith({
    double? latitude,
    double? longitude,
    DateTime? timestamp,
    Object? accuracyMeters = _unset,
    Object? altitudeMeters = _unset,
    SdkLocationSource? source,
    Object? deviceId = _unset,
    Object? hardwareId = _unset,
    Object? nodeId = _unset,
    Object? relayNodeId = _unset,
    Object? freshness = _unset,
    bool? isFresh,
    bool? isValid,
    bool? authoritativeForBackend,
  }) {
    final nextSource = source ?? this.source;
    final nextAuthority = authoritativeForBackend ??
        (source == null
            ? this.authoritativeForBackend
            : _defaultAuthorityForSource(nextSource));
    return SdkResolvedLocation(
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      timestamp: timestamp ?? this.timestamp,
      accuracyMeters: identical(accuracyMeters, _unset)
          ? this.accuracyMeters
          : accuracyMeters as double?,
      altitudeMeters: identical(altitudeMeters, _unset)
          ? this.altitudeMeters
          : altitudeMeters as double?,
      source: nextSource,
      deviceId:
          identical(deviceId, _unset) ? this.deviceId : deviceId as String?,
      hardwareId: identical(hardwareId, _unset)
          ? this.hardwareId
          : hardwareId as String?,
      nodeId: identical(nodeId, _unset) ? this.nodeId : nodeId as int?,
      relayNodeId: identical(relayNodeId, _unset)
          ? this.relayNodeId
          : relayNodeId as int?,
      freshness: identical(freshness, _unset)
          ? this.freshness
          : freshness as Duration?,
      isFresh: isFresh ?? this.isFresh,
      isValid: isValid ?? this.isValid,
      authoritativeForBackend:
          _coerceAuthorityForSource(nextSource, nextAuthority),
    );
  }

  static bool _isValidCoordinate(double latitude, double longitude) {
    return latitude.isFinite &&
        latitude >= -90 &&
        latitude <= 90 &&
        longitude.isFinite &&
        longitude >= -180 &&
        longitude <= 180 &&
        !(latitude == 0 && longitude == 0);
  }

  static bool _defaultAuthorityForSource(SdkLocationSource source) {
    return switch (source) {
      SdkLocationSource.connectedDevice || SdkLocationSource.phone => true,
      SdkLocationSource.backendSnapshot ||
      SdkLocationSource.remoteRelayDevice ||
      SdkLocationSource.cachedFallback ||
      SdkLocationSource.unknown =>
        false,
    };
  }

  static bool _coerceAuthorityForSource(
    SdkLocationSource source,
    bool authoritativeForBackend,
  ) {
    return switch (source) {
      SdkLocationSource.backendSnapshot ||
      SdkLocationSource.cachedFallback =>
        false,
      _ => authoritativeForBackend,
    };
  }

  static const Object _unset = Object();
}
