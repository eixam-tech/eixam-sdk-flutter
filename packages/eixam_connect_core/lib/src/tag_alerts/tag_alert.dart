import '../entities/sdk_resolved_location.dart';

enum TagAlertKind { batteryLow, tagDisconnected, bluetoothOff }

/// Battery bands derived from the TAG's existing 2-bit battery level
/// (`<30 %` and `<10 %`). They are never an exact percentage.
enum TagAlertBatteryThreshold { below30, below10 }

/// Last position reported by the TAG itself. Phone, cached and backend
/// positions are rejected so they can never be presented as the TAG position.
final class TagAlertPosition {
  TagAlertPosition({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    required this.source,
  }) {
    if (source != SdkLocationSource.connectedDevice) {
      throw ArgumentError.value(
        source,
        'source',
        'a TAG position must come from the connected TAG',
      );
    }
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180 ||
        (latitude == 0 && longitude == 0)) {
      throw ArgumentError('invalid TAG position coordinates');
    }
  }

  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final SdkLocationSource source;

  @override
  bool operator ==(Object other) =>
      other is TagAlertPosition &&
      other.latitude == latitude &&
      other.longitude == longitude &&
      other.timestamp == timestamp &&
      other.source == source;

  @override
  int get hashCode => Object.hash(latitude, longitude, timestamp, source);
}

/// Content of a TAG alert. Carries data only; wording comes from a
/// `TagAlertTextResolver`. Not an SOS type.
final class TagAlert {
  TagAlert({
    required this.kind,
    required this.deviceId,
    this.deviceAlias,
    this.batteryThreshold,
    this.elapsed,
    this.lastTagPosition,
  }) {
    if (deviceId.trim().isEmpty) {
      throw ArgumentError.value(deviceId, 'deviceId', 'must not be empty');
    }
    if ((kind == TagAlertKind.batteryLow) != (batteryThreshold != null)) {
      throw ArgumentError(
        'batteryThreshold is required for, and only for, batteryLow',
      );
    }
    if (kind == TagAlertKind.tagDisconnected) {
      final value = elapsed;
      if (value == null || value <= Duration.zero) {
        throw ArgumentError('tagDisconnected requires a positive elapsed');
      }
    } else if (elapsed != null) {
      throw ArgumentError('elapsed is only valid for tagDisconnected');
    }
  }

  final TagAlertKind kind;
  final String deviceId;
  final String? deviceAlias;
  final TagAlertBatteryThreshold? batteryThreshold;
  final Duration? elapsed;
  final TagAlertPosition? lastTagPosition;

  @override
  bool operator ==(Object other) =>
      other is TagAlert &&
      other.kind == kind &&
      other.deviceId == deviceId &&
      other.deviceAlias == deviceAlias &&
      other.batteryThreshold == batteryThreshold &&
      other.elapsed == elapsed &&
      other.lastTagPosition == lastTagPosition;

  @override
  int get hashCode => Object.hash(
    kind,
    deviceId,
    deviceAlias,
    batteryThreshold,
    elapsed,
    lastTagPosition,
  );
}
