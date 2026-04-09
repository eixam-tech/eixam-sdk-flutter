import 'package:eixam_connect_core/eixam_connect_core.dart';

DeviceStatus buildDeviceStatus({
  String deviceId = 'demo-device',
  String? canonicalHardwareId,
  String? deviceAlias = 'Demo Beacon',
  String? model = 'EIXAM R1',
  bool paired = true,
  bool activated = true,
  bool connected = true,
  int? batteryLevel = 2,
  DeviceBatteryLevel? batteryState = DeviceBatteryLevel.ok,
  DeviceBatterySource? batterySource = DeviceBatterySource.unknown,
  String? firmwareVersion = '1.0.0',
  DateTime? lastSeen,
  DateTime? lastSyncedAt,
  int? signalQuality = 4,
  DeviceLifecycleState lifecycleState = DeviceLifecycleState.ready,
  String? provisioningError,
}) {
  final timestamp = DateTime.utc(2026, 1, 1, 10);
  return DeviceStatus(
    deviceId: deviceId,
    canonicalHardwareId: canonicalHardwareId,
    deviceAlias: deviceAlias,
    model: model,
    paired: paired,
    activated: activated,
    connected: connected,
    batteryLevel: batteryLevel,
    batteryState: batteryState,
    batterySource: batterySource,
    firmwareVersion: firmwareVersion,
    lastSeen: lastSeen ?? timestamp,
    lastSyncedAt: lastSyncedAt ?? timestamp,
    signalQuality: signalQuality,
    lifecycleState: lifecycleState,
    provisioningError: provisioningError,
  );
}
