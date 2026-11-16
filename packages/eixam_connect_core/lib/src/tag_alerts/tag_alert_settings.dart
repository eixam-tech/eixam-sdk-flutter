/// Per-TAG alert preferences.
///
/// Instances are immutable and always valid: the factory rejects any
/// `disconnectAfter` outside [allowedDisconnectAfter].
final class TagAlertSettings {
  const TagAlertSettings._({
    required this.deviceId,
    required this.batteryAlerts,
    required this.disconnectAfter,
  });

  /// Defaults: battery alerts on, disconnect alert after
  /// [defaultDisconnectAfter]. Pass `disconnectAfter: null` for "never".
  factory TagAlertSettings({
    required String deviceId,
    bool batteryAlerts = true,
    Duration? disconnectAfter = defaultDisconnectAfter,
  }) {
    if (deviceId.trim().isEmpty) {
      throw ArgumentError.value(deviceId, 'deviceId', 'must not be empty');
    }
    if (!allowedDisconnectAfter.contains(disconnectAfter)) {
      throw ArgumentError.value(
        disconnectAfter,
        'disconnectAfter',
        'must be null (never) or one of $allowedDisconnectAfter',
      );
    }
    return TagAlertSettings._(
      deviceId: deviceId,
      batteryAlerts: batteryAlerts,
      disconnectAfter: disconnectAfter,
    );
  }

  /// Strict decoder. Throws [FormatException] for any malformed, unsupported
  /// or newer-version payload; callers must fall back to defaults explicitly.
  factory TagAlertSettings.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('TAG alert settings must be a JSON object.');
    }
    if (json['v'] is! int || json['v'] != schemaVersion) {
      throw const FormatException('Unsupported TAG alert settings version.');
    }
    final deviceId = json['deviceId'];
    final battery = json['batteryAlerts'];
    if (deviceId is! String || deviceId.trim().isEmpty || battery is! bool) {
      throw const FormatException('Invalid TAG alert settings fields.');
    }
    if (!json.containsKey('disconnectAfterMinutes')) {
      throw const FormatException('Missing disconnectAfterMinutes.');
    }
    final minutes = json['disconnectAfterMinutes'];
    if (minutes != null && minutes is! int) {
      throw const FormatException('Invalid disconnectAfterMinutes.');
    }
    final after = minutes == null ? null : Duration(minutes: minutes as int);
    if (!allowedDisconnectAfter.contains(after)) {
      throw const FormatException('Unsupported disconnectAfterMinutes.');
    }
    return TagAlertSettings._(
      deviceId: deviceId,
      batteryAlerts: battery,
      disconnectAfter: after,
    );
  }

  static const int schemaVersion = 1;
  static const Duration defaultDisconnectAfter = Duration(minutes: 5);

  /// `null` means "never notify about a disconnected TAG".
  static const List<Duration?> allowedDisconnectAfter = <Duration?>[
    null,
    Duration(minutes: 5),
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(minutes: 60),
  ];

  /// Stable device key; see `tagAlertDeviceKey`.
  final String deviceId;
  final bool batteryAlerts;

  /// How long the TAG may stay disconnected before a notification. `null` =
  /// never.
  final Duration? disconnectAfter;

  TagAlertSettings copyWith({
    bool? batteryAlerts,
    Object? disconnectAfter = _unset,
  }) {
    return TagAlertSettings(
      deviceId: deviceId,
      batteryAlerts: batteryAlerts ?? this.batteryAlerts,
      disconnectAfter: identical(disconnectAfter, _unset)
          ? this.disconnectAfter
          : disconnectAfter as Duration?,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'v': schemaVersion,
    'deviceId': deviceId,
    'batteryAlerts': batteryAlerts,
    'disconnectAfterMinutes': disconnectAfter?.inMinutes,
  };

  @override
  bool operator ==(Object other) =>
      other is TagAlertSettings &&
      other.deviceId == deviceId &&
      other.batteryAlerts == batteryAlerts &&
      other.disconnectAfter == disconnectAfter;

  @override
  int get hashCode => Object.hash(deviceId, batteryAlerts, disconnectAfter);

  @override
  String toString() =>
      'TagAlertSettings(deviceId: $deviceId, batteryAlerts: $batteryAlerts, '
      'disconnectAfter: $disconnectAfter)';

  static const Object _unset = Object();
}
