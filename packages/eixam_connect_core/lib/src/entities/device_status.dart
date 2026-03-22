import '../enums/device_lifecycle_state.dart';
import '../enums/device_battery_level.dart';
import '../enums/device_battery_source.dart';

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
  /// Raw EIXAM protocol battery value (`0..3`), not a true percentage.
  final int? batteryLevel;
  final DeviceBatteryLevel? batteryState;
  final DeviceBatterySource? batterySource;
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
    this.batteryState,
    this.batterySource,
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

  DeviceBatteryLevel? get effectiveBatteryState =>
      batteryState ?? DeviceBatteryLevel.fromProtocolValue(batteryLevel);

  int? get approximateBatteryPercentage =>
      effectiveBatteryState?.approximatePercentage;

  DeviceStatus copyWith({
    String? deviceId,
    String? deviceAlias,
    String? model,
    bool? paired,
    bool? activated,
    bool? connected,
    int? batteryLevel,
    DeviceBatteryLevel? batteryState,
    DeviceBatterySource? batterySource,
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
      batteryState: batteryState ?? this.batteryState,
      batterySource: batterySource ?? this.batterySource,
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
