import '../enums/device_battery_level.dart';
import '../enums/guided_rescue_target_state.dart';

class GuidedRescueStatusSnapshot {
  const GuidedRescueStatusSnapshot({
    required this.targetNodeId,
    required this.rescueNodeId,
    required this.targetState,
    required this.retryCount,
    required this.receivedAt,
    this.batteryLevel,
    this.gpsQuality,
    this.relayPendingAck = false,
    this.internetAvailable = false,
  });

  final int targetNodeId;
  final int rescueNodeId;
  final GuidedRescueTargetState targetState;
  final DeviceBatteryLevel? batteryLevel;
  final int? gpsQuality;
  final int retryCount;
  final bool relayPendingAck;
  final bool internetAvailable;
  final DateTime receivedAt;
}
