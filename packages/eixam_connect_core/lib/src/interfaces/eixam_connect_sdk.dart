import '../config/eixam_sdk_config.dart';
import '../config/eixam_session.dart';
import '../entities/death_man_plan.dart';
import '../entities/ble_notification_navigation_request.dart';
import '../entities/device_sos_status.dart';
import '../entities/device_status.dart';
import '../entities/emergency_contact.dart';
import '../entities/guided_rescue_state.dart';
import '../entities/permission_state.dart';
import '../entities/sos_incident.dart';
import '../entities/tracking_position.dart';
import '../enums/realtime_connection_state.dart';
import '../enums/sos_state.dart';
import '../enums/tracking_state.dart';
import '../events/eixam_sdk_event.dart';
import '../events/realtime_event.dart';

/// Public SDK contract consumed by host apps.
abstract class EixamConnectSdk {
  Future<void> initialize(EixamSdkConfig config);
  Future<void> setSession(EixamSession session);
  Future<void> clearSession();

  Future<DeviceStatus> pairDevice({required String pairingCode});
  Future<DeviceStatus> activateDevice({required String activationCode});
  Future<DeviceStatus> getDeviceStatus();
  Future<DeviceStatus> refreshDeviceStatus();
  Future<void> unpairDevice();
  Stream<DeviceStatus> watchDeviceStatus();
  Future<DeviceSosStatus> getDeviceSosStatus();
  Stream<DeviceSosStatus> watchDeviceSosStatus();
  Future<DeviceSosStatus> triggerDeviceSos();
  Future<DeviceSosStatus> confirmDeviceSos();
  Future<DeviceSosStatus> cancelDeviceSos();
  Future<DeviceSosStatus> acknowledgeDeviceSos();
  Future<void> sendInetOkToDevice();
  Future<void> sendInetLostToDevice();
  Future<void> sendPositionConfirmedToDevice();
  Future<void> sendSosAckRelayToDevice({required int nodeId});
  Future<void> sendShutdownToDevice();
  Future<BleNotificationNavigationRequest?>
  consumePendingBleNotificationNavigationRequest();
  Stream<BleNotificationNavigationRequest>
  watchBleNotificationNavigationRequests();

  Future<PermissionState> getPermissionState();
  Future<PermissionState> requestLocationPermission();
  Future<PermissionState> requestNotificationPermission();
  Future<PermissionState> requestBluetoothPermission();

  Future<void> initializeNotifications();
  Future<void> showLocalNotification({
    required String title,
    required String body,
  });

  Future<GuidedRescueState> getGuidedRescueState();
  Stream<GuidedRescueState> watchGuidedRescueState();
  Future<GuidedRescueState> setGuidedRescueSession({
    required int targetNodeId,
    required int rescueNodeId,
  });
  Future<void> clearGuidedRescueSession();
  Future<void> requestGuidedRescuePosition();
  Future<void> acknowledgeGuidedRescueSos();
  Future<void> enableGuidedRescueBuzzer();
  Future<void> disableGuidedRescueBuzzer();
  Future<void> requestGuidedRescueStatus();

  Future<void> startTracking();
  Future<void> stopTracking();
  Future<TrackingPosition?> getCurrentPosition();
  Future<TrackingState> getTrackingState();
  Stream<TrackingPosition> watchPositions();
  Stream<TrackingState> watchTrackingState();

  Future<SosIncident> triggerSos({
    String? message,
    String triggerSource = 'button_ui',
  });
  Future<SosIncident> cancelSos({String? reason});
  Future<SosState> getSosState();
  Stream<SosState> watchSosState();

  Future<List<EmergencyContact>> listEmergencyContacts();
  Stream<List<EmergencyContact>> watchEmergencyContacts();
  Future<EmergencyContact> addEmergencyContact({
    required String name,
    String? phone,
    String? email,
    int priority = 1,
    bool active = true,
  });
  Future<EmergencyContact> updateEmergencyContact(EmergencyContact contact);
  Future<void> setEmergencyContactActive(String contactId, bool active);
  Future<void> removeEmergencyContact(String contactId);

  Future<DeathManPlan> scheduleDeathMan({
    required DateTime expectedReturnAt,
    Duration gracePeriod = const Duration(minutes: 30),
    Duration checkInWindow = const Duration(minutes: 10),
    bool autoTriggerSos = true,
  });
  Future<DeathManPlan?> getActiveDeathManPlan();
  Future<void> confirmDeathManCheckIn(String planId);
  Future<void> cancelDeathMan(String planId);
  Stream<DeathManPlan> watchDeathManPlans();

  Stream<EixamSdkEvent> watchEvents();

  /// Returns the last known realtime transport connection state.
  Future<RealtimeConnectionState> getRealtimeConnectionState();

  /// Returns the last realtime event received by the SDK, if any.
  Future<RealtimeEvent?> getLastRealtimeEvent();

  /// Realtime transport connection lifecycle stream.
  Stream<RealtimeConnectionState> watchRealtimeConnectionState();

  /// Raw realtime events received by the SDK transport layer.
  Stream<RealtimeEvent> watchRealtimeEvents();
}
