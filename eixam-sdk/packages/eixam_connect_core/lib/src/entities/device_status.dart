import '../enums/device_lifecycle_state.dart';

/// Runtime view of the paired EIXAM device exposed by the SDK.
///
/// The host app can use this entity to render device health, activation,
/// connectivity and support information without being coupled to any BLE or
/// backend implementation detail.
class DeviceStatus {
  final String deviceId;
  final String? deviceAlias;
  final String? model;
  final bool paired;
  final bool activated;
  final bool connected;
  final int? batteryLevel;
  final String? firmwareVersion;
  final DateTime? lastSeen;
  final DateTime? lastSyncedAt;
  final int? signalQuality;
  final DeviceLifecycleState lifecycleState;
  final String? provisioningError;

  const DeviceStatus({
    required this.deviceId,
    this.deviceAlias,
    this.model,
    required this.paired,
    required this.activated,
    required this.connected,
    this.batteryLevel,
    this.firmwareVersion,
    this.lastSeen,
    this.lastSyncedAt,
    this.signalQuality,
    this.lifecycleState = DeviceLifecycleState.unpaired,
    this.provisioningError,
  });

  /// Returns `true` when the device can be considered operational for safety
  /// workflows such as location tracking and SOS triggering.
  bool get isReadyForSafety => paired && activated && connected;

  DeviceStatus copyWith({
    String? deviceId,
    String? deviceAlias,
    String? model,
    bool? paired,
    bool? activated,
    bool? connected,
    int? batteryLevel,
    String? firmwareVersion,
    DateTime? lastSeen,
    DateTime? lastSyncedAt,
    int? signalQuality,
    DeviceLifecycleState? lifecycleState,
    String? provisioningError,
    bool clearProvisioningError = false,
  }) {
    return DeviceStatus(
      deviceId: deviceId ?? this.deviceId,
      deviceAlias: deviceAlias ?? this.deviceAlias,
      model: model ?? this.model,
      paired: paired ?? this.paired,
      activated: activated ?? this.activated,
      connected: connected ?? this.connected,
      batteryLevel: batteryLevel ?? this.batteryLevel,
      firmwareVersion: firmwareVersion ?? this.firmwareVersion,
      lastSeen: lastSeen ?? this.lastSeen,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      signalQuality: signalQuality ?? this.signalQuality,
      lifecycleState: lifecycleState ?? this.lifecycleState,
      provisioningError: clearProvisioningError
          ? null
          : (provisioningError ?? this.provisioningError),
    );
  }
}
