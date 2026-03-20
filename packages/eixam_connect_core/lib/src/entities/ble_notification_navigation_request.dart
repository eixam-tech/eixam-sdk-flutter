import '../enums/device_sos_state.dart';

class BleNotificationNavigationRequest {
  const BleNotificationNavigationRequest({
    required this.actionId,
    required this.reason,
    required this.state,
    this.deviceId,
    this.deviceAlias,
    this.nodeId,
  });

  final String actionId;
  final String reason;
  final DeviceSosState state;
  final String? deviceId;
  final String? deviceAlias;
  final int? nodeId;
}
