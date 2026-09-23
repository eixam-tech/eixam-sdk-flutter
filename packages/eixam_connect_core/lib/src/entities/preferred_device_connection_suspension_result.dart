import 'device_status.dart';

/// Authoritative result of intentionally suspending the preferred TAG link.
class PreferredDeviceConnectionSuspensionResult {
  const PreferredDeviceConnectionSuspensionResult({
    required this.deviceStatus,
    required this.manualReconnectSuppressed,
    required this.reconnectCampaignActive,
    required this.lateAvailabilityWatcherActive,
    required this.connectionAttemptActive,
    required this.preferredDeviceRetained,
  });

  final DeviceStatus deviceStatus;
  final bool manualReconnectSuppressed;
  final bool reconnectCampaignActive;
  final bool lateAvailabilityWatcherActive;
  final bool connectionAttemptActive;
  final bool preferredDeviceRetained;

  bool get isQuiescent =>
      !deviceStatus.connected &&
      manualReconnectSuppressed &&
      !reconnectCampaignActive &&
      !lateAvailabilityWatcherActive &&
      !connectionAttemptActive;
}
