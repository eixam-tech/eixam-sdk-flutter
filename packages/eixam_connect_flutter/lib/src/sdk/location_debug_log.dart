import 'dart:math' as math;

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../device/ble_debug_registry.dart';

class LocationDebugLog {
  const LocationDebugLog._();

  static const String tag = '[EIXAM_LOCATION_AUTH]';
  static const double _suspiciousJumpKm = 50;
  static const Duration _suspiciousJumpWindow = Duration(minutes: 10);

  static _DebugLocation? _lastAccepted;

  static void resolved({
    required String flow,
    required SdkResolvedLocation? location,
    required bool accepted,
    String? rejectionReason,
    bool persisted = false,
    bool sentToBackend = false,
    bool authoritativeForBackend = true,
    String? note,
  }) {
    if (location == null) {
      _record(
        flow: flow,
        source: 'none',
        accepted: accepted,
        rejectionReason: rejectionReason ?? 'missing_location',
        persisted: persisted,
        sentToBackend: sentToBackend,
        note: note,
      );
      return;
    }
    final debugLocation = _DebugLocation(
      latitude: location.latitude,
      longitude: location.longitude,
      altitude: location.altitudeMeters,
      accuracy: location.accuracyMeters,
      timestamp: location.timestamp,
      source: location.source.name,
      authoritativeForBackend: location.authoritativeForBackend,
      deviceId: location.deviceId,
      hardwareId: location.hardwareId,
      nodeId: location.nodeId,
      relayNodeId: location.relayNodeId,
      isValid: location.isValid,
      isFresh: location.isFresh,
      freshness: location.freshness,
    );
    _recordLocation(
      flow: flow,
      location: debugLocation,
      accepted: accepted,
      rejectionReason: rejectionReason,
      persisted: persisted,
      sentToBackend: sentToBackend,
      note: note,
    );
  }

  static void telemetryPayload({
    required String flow,
    required SdkTelemetryPayload payload,
    required bool accepted,
    String? source,
    String? rejectionReason,
    bool persisted = false,
    bool sentToBackend = false,
    bool? authoritativeForBackend,
    String? note,
  }) {
    final debugLocation = _DebugLocation(
      latitude: payload.latitude,
      longitude: payload.longitude,
      altitude: payload.altitude,
      accuracy: null,
      timestamp: payload.timestamp,
      source: source ?? payload.identitySource ?? 'unknown',
      authoritativeForBackend: authoritativeForBackend,
      deviceId: payload.deviceId,
      hardwareId: payload.hardwareId,
      nodeId: payload.nodeId,
      relayNodeId: null,
      isValid: _isValidCoordinate(payload.latitude, payload.longitude),
      isFresh: null,
      freshness: null,
    );
    _recordLocation(
      flow: flow,
      location: debugLocation,
      accepted: accepted,
      rejectionReason: rejectionReason,
      persisted: persisted,
      sentToBackend: sentToBackend,
      note: note,
    );
  }

  static void raw({
    required String flow,
    required String source,
    required double latitude,
    required double longitude,
    required DateTime timestamp,
    required bool accepted,
    double? altitude,
    double? accuracy,
    String? rejectionReason,
    bool authoritativeForBackend = false,
    bool persisted = false,
    bool sentToBackend = false,
    String? deviceId,
    String? hardwareId,
    int? nodeId,
    int? relayNodeId,
    String? note,
  }) {
    final debugLocation = _DebugLocation(
      latitude: latitude,
      longitude: longitude,
      altitude: altitude,
      accuracy: accuracy,
      timestamp: timestamp,
      source: source,
      authoritativeForBackend: authoritativeForBackend,
      deviceId: deviceId,
      hardwareId: hardwareId,
      nodeId: nodeId,
      relayNodeId: relayNodeId,
      isValid: _isValidCoordinate(latitude, longitude),
      isFresh: null,
      freshness: null,
    );
    _recordLocation(
      flow: flow,
      location: debugLocation,
      accepted: accepted,
      rejectionReason: rejectionReason,
      persisted: persisted,
      sentToBackend: sentToBackend,
      note: note,
    );
  }

  static void availability({
    required String flow,
    required String source,
    required bool accepted,
    String? rejectionReason,
    bool persisted = false,
    bool sentToBackend = false,
    bool? authoritativeForBackend,
    double? latitude,
    double? longitude,
    double? altitude,
    double? accuracy,
    DateTime? timestamp,
    bool? isValid,
    bool? isFresh,
    Duration? freshness,
    String? deviceId,
    String? hardwareId,
    int? nodeId,
    int? relayNodeId,
    bool? candidateExists,
    bool? connected,
    bool? runtimeReady,
    DateTime? latestTelTimestamp,
    Duration? latestTelAge,
    String? packetType,
    String? classification,
    bool? hasLocation,
    int? gpsQuality,
    String? rawHex,
    String? note,
  }) {
    final details = <String>[
      if (candidateExists != null) 'candidateExists=$candidateExists',
      if (connected != null) 'connected=$connected',
      if (runtimeReady != null) 'runtimeReady=$runtimeReady',
      if (latestTelTimestamp != null)
        'latestTelTimestamp=${latestTelTimestamp.toUtc().toIso8601String()}',
      if (latestTelAge != null) 'latestTelAgeMs=${latestTelAge.inMilliseconds}',
      if (packetType != null && packetType.trim().isNotEmpty)
        'packetType=${packetType.trim()}',
      if (classification != null && classification.trim().isNotEmpty)
        'classification=${classification.trim()}',
      if (hasLocation != null) 'hasLocation=$hasLocation',
      if (gpsQuality != null) 'gpsQuality=$gpsQuality',
      if (rawHex != null && rawHex.trim().isNotEmpty) 'raw=${rawHex.trim()}',
      if (note != null && note.trim().isNotEmpty) note.trim(),
    ].join(' ');
    _record(
      flow: flow,
      source: source,
      accepted: accepted,
      rejectionReason: rejectionReason,
      persisted: persisted,
      sentToBackend: sentToBackend,
      latitude: latitude,
      longitude: longitude,
      altitude: altitude,
      accuracy: accuracy,
      timestamp: timestamp,
      freshness: freshness,
      authoritativeForBackend: authoritativeForBackend,
      isValid: isValid,
      isFresh: isFresh,
      deviceId: deviceId,
      hardwareId: hardwareId,
      nodeId: nodeId,
      relayNodeId: relayNodeId,
      note: details.isEmpty ? null : details,
    );
  }

  static void _recordLocation({
    required String flow,
    required _DebugLocation location,
    required bool accepted,
    String? rejectionReason,
    required bool persisted,
    required bool sentToBackend,
    String? note,
  }) {
    _checkSuspiciousJump(flow: flow, location: location, accepted: accepted);
    if (accepted &&
        location.authoritativeForBackend == true &&
        location.isValid &&
        _isLiveSource(location.source)) {
      _lastAccepted = location;
    }
    _record(
      flow: flow,
      source: location.source,
      accepted: accepted,
      rejectionReason: rejectionReason,
      persisted: persisted,
      sentToBackend: sentToBackend,
      latitude: location.latitude,
      longitude: location.longitude,
      altitude: location.altitude,
      accuracy: location.accuracy,
      timestamp: location.timestamp,
      freshness: location.freshness,
      authoritativeForBackend: location.authoritativeForBackend,
      isValid: location.isValid,
      isFresh: location.isFresh,
      deviceId: location.deviceId,
      hardwareId: location.hardwareId,
      nodeId: location.nodeId,
      relayNodeId: location.relayNodeId,
      note: note,
    );
  }

  static void _record({
    required String flow,
    required String source,
    required bool accepted,
    String? rejectionReason,
    required bool persisted,
    required bool sentToBackend,
    double? latitude,
    double? longitude,
    double? altitude,
    double? accuracy,
    DateTime? timestamp,
    Duration? freshness,
    bool? authoritativeForBackend,
    bool? isValid,
    bool? isFresh,
    String? deviceId,
    String? hardwareId,
    int? nodeId,
    int? relayNodeId,
    String? note,
  }) {
    final now = DateTime.now().toUtc();
    final normalizedTimestamp = timestamp?.toUtc();
    final ageMs = normalizedTimestamp == null
        ? 'none'
        : now.difference(normalizedTimestamp).inMilliseconds.toString();
    BleDebugRegistry.instance.recordEvent(
      '$tag flow=$flow '
      'source=$source '
      'lat=${latitude?.toStringAsFixed(6) ?? "none"} '
      'lon=${longitude?.toStringAsFixed(6) ?? "none"} '
      'alt=${altitude?.toStringAsFixed(2) ?? "none"} '
      'accuracy=${accuracy?.toStringAsFixed(2) ?? "none"} '
      'timestamp=${normalizedTimestamp?.toIso8601String() ?? "none"} '
      'ageMs=$ageMs '
      'freshnessMs=${freshness?.inMilliseconds.toString() ?? "none"} '
      'authoritativeForBackend=${authoritativeForBackend?.toString() ?? "unknown"} '
      'isFresh=${isFresh?.toString() ?? "unknown"} '
      'isValid=${isValid?.toString() ?? "unknown"} '
      'deviceId=${_safeId(deviceId)} '
      'hardwareId=${_safeId(hardwareId)} '
      'nodeId=${nodeId?.toString() ?? "none"} '
      'relayNodeId=${relayNodeId?.toString() ?? "none"} '
      'accepted=$accepted '
      'rejectionReason=${rejectionReason ?? "none"} '
      'persisted=$persisted '
      'sentToBackend=$sentToBackend'
      '${note == null ? "" : " note=$note"}',
    );
  }

  static void _checkSuspiciousJump({
    required String flow,
    required _DebugLocation location,
    required bool accepted,
  }) {
    if (!accepted ||
        location.authoritativeForBackend != true ||
        !location.isValid ||
        !_isLiveSource(location.source)) {
      return;
    }
    final previous = _lastAccepted;
    if (previous == null || !previous.isValid || previous.timestamp == null) {
      return;
    }
    final timestamp = location.timestamp;
    if (timestamp == null) {
      return;
    }
    final elapsed =
        timestamp.toUtc().difference(previous.timestamp!.toUtc()).abs();
    if (elapsed > _suspiciousJumpWindow) {
      return;
    }
    final distanceKm = _distanceKm(
      previous.latitude!,
      previous.longitude!,
      location.latitude!,
      location.longitude!,
    );
    if (distanceKm <= _suspiciousJumpKm) {
      return;
    }
    BleDebugRegistry.instance.recordEvent(
      '$tag[suspicious_jump] flow=$flow '
      'previousLat=${previous.latitude!.toStringAsFixed(6)} '
      'previousLon=${previous.longitude!.toStringAsFixed(6)} '
      'newLat=${location.latitude!.toStringAsFixed(6)} '
      'newLon=${location.longitude!.toStringAsFixed(6)} '
      'distanceKm=${distanceKm.toStringAsFixed(2)} '
      'elapsedMs=${elapsed.inMilliseconds} '
      'previousSource=${previous.source} '
      'newSource=${location.source}',
    );
  }

  static bool _isLiveSource(String source) {
    final normalized = source.trim().toLowerCase();
    return normalized == 'connecteddevice' ||
        normalized == 'phone' ||
        normalized == 'ble_node' ||
        normalized == 'app' ||
        normalized == 'device_hardware' ||
        normalized == 'device_hardware_pending';
  }

  static bool _isValidCoordinate(double? latitude, double? longitude) {
    if (latitude == null || longitude == null) {
      return false;
    }
    return latitude.isFinite &&
        latitude >= -90 &&
        latitude <= 90 &&
        longitude.isFinite &&
        longitude >= -180 &&
        longitude <= 180 &&
        !(latitude == 0 && longitude == 0);
  }

  static double _distanceKm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadiusKm = 6371.0;
    final dLat = _degreesToRadians(lat2 - lat1);
    final dLon = _degreesToRadians(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degreesToRadians(lat1)) *
            math.cos(_degreesToRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return earthRadiusKm * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _degreesToRadians(double degrees) => degrees * math.pi / 180;

  static String _safeId(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return 'none';
    }
    return trimmed.length <= 24 ? trimmed : '${trimmed.substring(0, 24)}...';
  }
}

class _DebugLocation {
  const _DebugLocation({
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.accuracy,
    required this.timestamp,
    required this.source,
    required this.authoritativeForBackend,
    required this.deviceId,
    required this.hardwareId,
    required this.nodeId,
    required this.relayNodeId,
    required this.isValid,
    required this.isFresh,
    required this.freshness,
  });

  final double? latitude;
  final double? longitude;
  final double? altitude;
  final double? accuracy;
  final DateTime? timestamp;
  final String source;
  final bool? authoritativeForBackend;
  final String? deviceId;
  final String? hardwareId;
  final int? nodeId;
  final int? relayNodeId;
  final bool isValid;
  final bool? isFresh;
  final Duration? freshness;
}
