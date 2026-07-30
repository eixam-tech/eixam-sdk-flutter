import '../enums/device_lifecycle_state.dart';
import '../enums/device_battery_level.dart';
import '../enums/device_battery_source.dart';

/// Runtime view of the paired EIXAM device exposed by the SDK.
///
/// The host app can use this entity to render device health, activation,
/// connectivity and support information without being coupled to any BLE or
/// backend implementation detail.
class DeviceStatus {
  const DeviceStatus({
    required this.deviceId,
    this.nodeId,
    this.canonicalHardwareId,
    this.deviceAlias,
    this.model,
    required this.paired,
    required this.activated,
    required this.connected,
    this.batteryPercent,
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
  final String deviceId;
  final int? nodeId;
  final String? canonicalHardwareId;
  final String? deviceAlias;
  final String? model;
  final bool paired;
  final bool activated;
  final bool connected;

  /// Exact battery percentage (`0..100`) when the runtime can provide one.
  ///
  /// This is intentionally separate from [batteryLevel], which is the lossy
  /// 2-bit value embedded in TEL and SOS packets.
  final int? batteryPercent;

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

  /// Returns `true` when the device can be considered operational for safety
  /// workflows such as location tracking and SOS triggering.
  bool get isReadyForSafety => paired && activated && connected;

  DeviceBatteryLevel? get effectiveBatteryState =>
      DeviceBatteryLevel.fromPercentage(batteryPercent) ??
      batteryState ??
      DeviceBatteryLevel.fromProtocolValue(batteryLevel);

  /// Exact percentage when available, otherwise the UI-only 2-bit estimate.
  int? get approximateBatteryPercentage =>
      batteryPercent ?? effectiveBatteryState?.approximatePercentage;

  DeviceStatus copyWith({
    String? deviceId,
    int? nodeId,
    Object? canonicalHardwareId = _unset,
    String? deviceAlias,
    String? model,
    bool? paired,
    bool? activated,
    bool? connected,
    Object? batteryPercent = _unset,
    Object? batteryLevel = _unset,
    Object? batteryState = _unset,
    Object? batterySource = _unset,
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
      nodeId: nodeId ?? this.nodeId,
      canonicalHardwareId: identical(canonicalHardwareId, _unset)
          ? this.canonicalHardwareId
          : canonicalHardwareId as String?,
      deviceAlias: deviceAlias ?? this.deviceAlias,
      model: model ?? this.model,
      paired: paired ?? this.paired,
      activated: activated ?? this.activated,
      connected: connected ?? this.connected,
      batteryPercent: identical(batteryPercent, _unset)
          ? this.batteryPercent
          : batteryPercent as int?,
      batteryLevel: identical(batteryLevel, _unset)
          ? this.batteryLevel
          : batteryLevel as int?,
      batteryState: identical(batteryState, _unset)
          ? this.batteryState
          : batteryState as DeviceBatteryLevel?,
      batterySource: identical(batterySource, _unset)
          ? this.batterySource
          : batterySource as DeviceBatterySource?,
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

const Object _unset = Object();
