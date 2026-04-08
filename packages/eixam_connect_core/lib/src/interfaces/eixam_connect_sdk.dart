import '../config/eixam_bootstrap_config.dart';
import '../config/eixam_sdk_config.dart';
import '../config/eixam_session.dart';
import '../entities/death_man_plan.dart';
import '../entities/ble_notification_navigation_request.dart';
import '../entities/backend_registered_device.dart';
import '../entities/device_sos_status.dart';
import '../entities/device_status.dart';
import '../entities/emergency_contact.dart';
import '../entities/guided_rescue_state.dart';
import '../entities/permission_state.dart';
import '../entities/preferred_device.dart';
import '../entities/protection_mode_models.dart';
import '../entities/sdk_operational_diagnostics.dart';
import '../entities/sdk_telemetry_payload.dart';
import '../entities/sos_incident.dart';
import '../entities/sos_trigger_payload.dart';
import '../entities/tracking_position.dart';
import '../enums/realtime_connection_state.dart';
import '../enums/sos_state.dart';
import '../enums/tracking_state.dart';
import '../events/eixam_sdk_event.dart';
import '../events/realtime_event.dart';

/// Public SDK contract consumed by host apps.
typedef EixamConnectSdkBootstrapper = Future<EixamConnectSdk> Function(
  EixamBootstrapConfig config,
);

EixamConnectSdkBootstrapper? _bootstrapper;

void registerEixamConnectSdkBootstrapper(
  EixamConnectSdkBootstrapper bootstrapper,
) {
  _bootstrapper = bootstrapper;
}

abstract class EixamConnectSdk {
  static Future<EixamConnectSdk> bootstrap(EixamBootstrapConfig config) {
    final bootstrapper = _bootstrapper;
    if (bootstrapper == null) {
      throw UnsupportedError(
        'No EIXAM SDK bootstrapper is registered. Import '
        '`package:eixam_connect_flutter/eixam_connect_flutter.dart` before '
        'calling EixamConnectSdk.bootstrap(...).',
      );
    }
    return bootstrapper(config);
  }

  Future<void> initialize(EixamSdkConfig config);

  /// Stores the signed SDK identity payload provided by the host app.
  ///
  /// Host apps are expected to obtain `appId`, `externalUserId`, and
  /// `userHash` from their own backend or partner backend. The mobile SDK does
  /// not call partner signing routes and does not compute the hash locally.
  Future<void> setSession(EixamSession session);

  /// Clears the currently persisted SDK identity payload.
  Future<void> clearSession();

  Future<EixamSession?> getCurrentSession();

  /// Re-fetches the canonical SDK identity from `/v1/sdk/me`.
  Future<EixamSession> refreshCanonicalIdentity();

  Future<SdkOperationalDiagnostics> getOperationalDiagnostics();
  Stream<SdkOperationalDiagnostics> watchOperationalDiagnostics();
  Future<ProtectionReadinessReport> evaluateProtectionReadiness();
  Future<EnterProtectionModeResult> enterProtectionMode({
    ProtectionModeOptions options = const ProtectionModeOptions(),
  });
  Future<ProtectionStatus> exitProtectionMode();
  Future<ProtectionStatus> getProtectionStatus();
  Stream<ProtectionStatus> watchProtectionStatus();
  Future<ProtectionDiagnostics> getProtectionDiagnostics();
  Stream<ProtectionDiagnostics> watchProtectionDiagnostics();
  Future<ProtectionStatus> rehydrateProtectionState();
  Future<FlushProtectionQueuesResult> flushProtectionQueues();

  Future<DeviceStatus> connectDevice({required String pairingCode});
  Future<void> disconnectDevice();
  Future<PreferredDevice?> get preferredDevice;
  Stream<DeviceStatus> get deviceStatusStream;

  Future<List<BackendRegisteredDevice>> listRegisteredDevices();
  Future<BackendRegisteredDevice> upsertRegisteredDevice({
    required String hardwareId,
    required String firmwareVersion,
    required String hardwareModel,
    required DateTime pairedAt,
  });
  Future<void> deleteRegisteredDevice(String deviceId);

  Future<SosIncident> triggerSos(SosTriggerPayload payload);
  Future<SosIncident?> getCurrentSosIncident();
  Stream<SosState> get currentSosStateStream;
  Stream<EixamSdkEvent> get lastSosEventStream;

  Future<EmergencyContact> createEmergencyContact({
    required String name,
    required String phone,
    required String email,
    int priority = 1,
  });
  Future<void> deleteEmergencyContact(String contactId);

  @Deprecated('Use connectDevice instead.')
  Future<DeviceStatus> pairDevice({required String pairingCode});
  Future<DeviceStatus> activateDevice({required String activationCode});
  Future<DeviceStatus> getDeviceStatus();
  Future<DeviceStatus> refreshDeviceStatus();
  @Deprecated('Use disconnectDevice instead.')
  Future<void> unpairDevice();
  @Deprecated('Use deviceStatusStream instead.')
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
  Future<void> publishTelemetry(SdkTelemetryPayload payload);
  Future<TrackingPosition?> getCurrentPosition();
  Future<TrackingState> getTrackingState();
  Stream<TrackingPosition> watchPositions();
  Stream<TrackingState> watchTrackingState();

  Future<SosIncident> cancelSos();
  Future<SosState> getSosState();
  @Deprecated('Use currentSosStateStream instead.')
  Stream<SosState> watchSosState();

  Future<List<EmergencyContact>> listEmergencyContacts();
  Stream<List<EmergencyContact>> watchEmergencyContacts();
  @Deprecated('Use createEmergencyContact instead.')
  Future<EmergencyContact> addEmergencyContact({
    required String name,
    required String phone,
    required String email,
    int priority = 1,
  });
  Future<EmergencyContact> updateEmergencyContact(EmergencyContact contact);
  @Deprecated('Use deleteEmergencyContact instead.')
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
