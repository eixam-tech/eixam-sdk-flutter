import '../config/eixam_bootstrap_config.dart';
import '../config/eixam_sdk_config.dart';
import '../config/eixam_session.dart';
import '../entities/death_man_plan.dart';
import '../entities/ble_notification_navigation_request.dart';
import '../entities/backend_registered_device.dart';
import '../entities/ble_command_channel_status.dart';
import '../entities/device_country_config_status.dart';
import '../entities/device_sos_status.dart';
import '../entities/device_status.dart';
import '../entities/device_runtime_status.dart';
import '../entities/eixam_ble_diagnostics.dart';
import '../entities/eixam_ble_scan_result.dart';
import '../entities/eixam_device_position_batch.dart';
import '../entities/emergency_contact.dart';
import '../entities/eixam_notification_intent.dart';
import '../entities/app_feedback.dart';
import '../entities/firmware_update.dart';
import '../entities/permission_state.dart';
import '../entities/preferred_device.dart';
import '../entities/preferred_device_reconnect_result.dart';
import '../entities/protection_mode_models.dart';
import '../entities/public_pre_sos_status.dart';
import '../entities/os_sos_widget_activation.dart';
import '../entities/runtime_identity_snapshot.dart';
import '../entities/permission_disclosure.dart';
import '../entities/sdk_operational_diagnostics.dart';
import '../entities/sdk_resolved_location.dart';
import '../entities/sdk_user_profile.dart';
import '../entities/sdk_telemetry_payload.dart';
import '../entities/sos_history_item.dart';
import '../entities/sos_incident.dart';
import '../entities/sos_incident_progress.dart';
import '../entities/sos_lifecycle.dart';
import '../entities/sos_capability_snapshot.dart';
import '../entities/sos_trigger_payload.dart';
import '../entities/tracking_position.dart';
import '../enums/realtime_connection_state.dart';
import '../enums/sos_state.dart';
import '../enums/sos_terminal_reason.dart';
import '../enums/tracking_state.dart';
import '../events/eixam_sdk_event.dart';
import '../events/realtime_event.dart';

/// Public SDK contract consumed by host apps.
typedef EixamConnectSdkBootstrapper = Future<EixamConnectSdk> Function(
    EixamBootstrapConfig config);

EixamConnectSdkBootstrapper? _bootstrapper;

void registerEixamConnectSdkBootstrapper(
  EixamConnectSdkBootstrapper bootstrapper,
) {
  _bootstrapper = bootstrapper;
}

abstract class EixamConnectSdk {
  /// Canonical guarded PRE-SOS countdown used by in-app and OS widget flows.
  static const Duration defaultPreSosCountdown = Duration(seconds: 20);

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
  Future<void> setSession(
    EixamSession session, {
    bool deferRuntimeWork = false,
  });

  /// Starts runtime work skipped by [setSession] when `deferRuntimeWork` is set.
  Future<void> startDeferredRuntime();

  /// Clears SDK-owned local user/session data from device storage only.
  ///
  /// This does not call remote deletion endpoints and is safe to call multiple
  /// times during logout or account-deletion cleanup.
  Future<void> clearLocalUserData();

  /// Clears the currently persisted SDK identity payload and local SDK user
  /// data for logout semantics.
  Future<void> clearSession();

  Future<EixamSession?> getCurrentSession();

  /// Re-fetches the canonical SDK identity from `/v1/sdk/me`.
  Future<EixamSession> refreshCanonicalIdentity();

  /// Loads the authenticated SDK user's profile from `GET /v1/sdk/me`.
  ///
  /// Requires an HTTP-backed SDK runtime with profile routes enabled.
  Future<SdkUserProfile> fetchSdkUserProfile();

  /// Updates the authenticated SDK user's profile via `PUT /v1/sdk/me`.
  Future<SdkUserProfile> updateSdkUserProfile(SdkUserProfileUpdate update);

  /// Deletes SDK-owned data for the authenticated user via `DELETE /v1/sdk/me`.
  ///
  /// Host apps still orchestrate account deletion across SDK erasure, auth
  /// deletion, and app-local wipe. This method also clears SDK-owned local
  /// user data in a `finally` block, even when the remote erasure fails.
  Future<void> deleteUserData({
    required String userHash,
    required String externalUserId,
  });

  /// Submits authenticated in-app feedback to `POST /v1/feedback`.
  ///
  /// The SDK uses the current SDK session for `app_id` and `sdk_user_id`.
  /// [userAccessToken] must be the current authenticated Eixam user JWT.
  /// This endpoint is not available through SDK HMAC-only authentication and
  /// is intentionally not signed with the SDK `userHash`.
  Future<AppFeedbackSubmission> submitAppFeedback({
    required String description,
    required String userAccessToken,
  });

  Future<SdkOperationalDiagnostics> getOperationalDiagnostics();
  Stream<SdkOperationalDiagnostics> watchOperationalDiagnostics();
  Future<SosCapabilitySnapshot> getSosCapability();
  Stream<SosCapabilitySnapshot> watchSosCapability();
  Future<SosCapabilitySnapshot> retrySosCapability();
  Future<SdkResolvedLocation?> getResolvedLocationForEmergencyContext();
  Stream<SdkResolvedLocation?> watchResolvedLocation();

  /// Watches real positions sampled by the connected TAG and delivered in a
  /// live BLE `0xD3` batch. Each event preserves firmware order (oldest first).
  Stream<EixamDevicePositionBatch> watchDevicePositionBatches();
  Future<SdkTelemetryPayload?> getResolvedTelemetryPreview({
    bool includeCachedFallback = true,
  });

  /// Enables the legacy background-telemetry sharing behavior.
  ///
  /// A future background-location implementation will map this to activation
  /// of the `sharing` background-location context. Disabling legacy sharing will
  /// remove only that context and must not stop an active SOS or DMP context.
  Future<void> enableBackgroundTelemetry({
    String? notificationTitle,
    String? notificationBody,
  });

  /// Disables only the legacy background-telemetry sharing behavior.
  ///
  /// This API remains unchanged in phase 1; no context mapping is performed.
  Future<void> disableBackgroundTelemetry();
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
  Future<List<EixamBleScanResult>> scanBleDevices({
    Duration timeout = const Duration(seconds: 8),
  });
  Future<EixamBleDiagnostics> getBleDiagnostics();
  Stream<EixamBleDiagnostics> watchBleDiagnostics();
  Future<BleCommandChannelStatus> getDeviceCommandChannelStatus();
  Stream<BleCommandChannelStatus> watchDeviceCommandChannelStatus();
  Future<PreferredDevice?> get preferredDevice;
  Stream<DeviceStatus> get deviceStatusStream;
  Future<PreferredDeviceReconnectResult> bootstrapPreferredDeviceReconnect({
    String reason = 'startup',
    String? attemptId,
    String? platformRemoteId,
  });
  Future<void> startPreferredDeviceReconnectMonitor({
    String reason = 'ble_ready',
  });
  Future<void> stopPreferredDeviceReconnectMonitor();
  Future<PreferredDeviceReconnectResult> reconnectPreferredDevice({
    required String reason,
    String? attemptId,
    String? platformRemoteId,
  });

  Future<List<BackendRegisteredDevice>> listRegisteredDevices();
  Future<BackendRegisteredDevice> upsertRegisteredDevice({
    required String hardwareId,
    required String firmwareVersion,
    required String hardwareModel,
    required DateTime pairedAt,
  });
  Future<void> registerDeviceIdentityMapping({
    required String hardwareId,
    required int nodeId,
    String? source,
  });
  Future<void> deleteRegisteredDevice(String deviceId);

  Future<void> startPreSos({Duration countdown = defaultPreSosCountdown});
  Future<SosIncident> confirmPreSos(SosTriggerPayload payload);
  Future<void> cancelPreSos();
  Future<PublicPreSosStatus?> getPreSosStatus();
  Stream<PublicPreSosStatus?> watchPreSosStatus();
  Future<OsSosWidgetActivationResult> handleOsSosWidgetActivation(
    OsSosWidgetActivation activation, {
    Duration countdown = defaultPreSosCountdown,
  });
  Future<SosIncident> triggerSos(SosTriggerPayload payload);
  Future<SosActivationResult> triggerSosAuthoritatively(
    SosTriggerPayload payload,
  );
  Future<SosLifecycleSnapshot> getSosLifecycle();
  Stream<SosLifecycleSnapshot> get sosLifecycleStream;
  Future<SosIncident?> getCurrentSosIncident();
  Future<SosTerminalReason?> getCurrentSosTerminalReason();
  Stream<SosState> get currentSosStateStream;
  Stream<EixamSdkEvent> get lastSosEventStream;

  Future<EmergencyContact> createEmergencyContact({
    required String name,
    required String phone,
    required String email,
    int priority = 1,
    String language = 'en',
  });
  Future<void> deleteEmergencyContact(String contactId);

  /// Reorders contacts by id; backend assigns priority from list order.
  Future<void> reorderEmergencyContacts(List<String> orderedContactIds);

  @Deprecated('Use connectDevice instead.')
  Future<DeviceStatus> pairDevice({required String pairingCode});
  Future<DeviceStatus> activateDevice({required String activationCode});
  Future<DeviceStatus> getDeviceStatus();
  Future<DeviceStatus> refreshDeviceStatus();
  Future<DeviceFirmwareInfo> getFirmwareInfo({String? deviceId});
  Future<List<FirmwareRelease>> listFirmwareReleases({String? deviceId});
  Future<FirmwareUpdateCheck> checkFirmwareUpdate({
    String? deviceId,
    FirmwareUpdatePolicy policy = const FirmwareUpdatePolicy(),
  });
  Future<FirmwareUpdateSession> startFirmwareUpdate({
    required String deviceId,
    required String releaseId,
    FirmwareUpdatePolicy policy = const FirmwareUpdatePolicy(),
  });
  Stream<FirmwareUpdateProgress> watchFirmwareUpdateProgress({
    String? deviceId,
  });
  Future<void> cancelFirmwareUpdate(String sessionId);
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
  Future<void> setDeviceNotificationVolume(int volume);
  Future<void> setDeviceSosVolume(int volume);
  Future<DeviceRuntimeStatus> getDeviceRuntimeStatus();
  Future<RuntimeIdentitySnapshot> getRuntimeIdentitySnapshot();
  Future<void> rebootDevice();

  /// Most recent per-country radio-config (LoRa region) apply outcome.
  Future<DeviceCountryConfigStatus> getDeviceCountryConfigStatus();

  /// Emits each per-country radio-config apply outcome as it is produced.
  Stream<DeviceCountryConfigStatus> watchDeviceCountryConfigStatus();

  /// Checks the connected device against the backend config for its current
  /// country. A mismatch is surfaced as `updateAvailable`; this method never
  /// writes a region or reboots the device.
  ///
  /// [countryIsoOverride] is intended for host development tools. It bypasses
  /// phone geolocation only; backend config lookup, device comparison, user
  /// confirmation, apply and verification remain the production path.
  Future<DeviceCountryConfigStatus> checkDeviceCountryConfig({
    String reason,
    String? countryIsoOverride,
  });

  /// Applies the mismatch most recently produced by
  /// [checkDeviceCountryConfig]. Hosts must call this only after explicit user
  /// confirmation. The SDK re-checks device identity, safety and live region
  /// immediately before the write and reboot.
  Future<DeviceCountryConfigStatus> applyPendingDeviceCountryConfig({
    String reason,
  });

  /// Deprecated compatibility alias for [checkDeviceCountryConfig]. It only
  /// detects a mismatch and never writes or reboots. Hosts must call
  /// [applyPendingDeviceCountryConfig] after explicit user confirmation.
  @Deprecated(
    'Use checkDeviceCountryConfig, then applyPendingDeviceCountryConfig after '
    'explicit user confirmation.',
  )
  Future<DeviceCountryConfigStatus> ensureDeviceCountryConfig({String reason});

  Future<BleNotificationNavigationRequest?>
      consumePendingBleNotificationNavigationRequest();
  Stream<BleNotificationNavigationRequest>
      watchBleNotificationNavigationRequests();
  Future<List<EixamNotificationIntent>> consumePendingNotificationIntents();
  Stream<EixamNotificationIntent> watchNotificationIntents();

  Future<PermissionState> getPermissionState();
  Future<EixamPermissionPreflightResult> preparePermissionPreflight(
    EixamPermissionRequirement requirement,
  );
  Future<EixamPermissionPreflightResult> acceptPermissionDisclosure(
    EixamPermissionRequirement requirement,
  );
  Future<EixamPermissionPreflightResult> declinePermissionDisclosure(
    EixamPermissionRequirement requirement,
  );
  Future<PermissionState> requestLocationPermission();
  Future<PermissionState> requestNotificationPermission();
  Future<PermissionState> requestBluetoothPermission();

  Future<void> initializeNotifications();
  Future<void> showLocalNotification({
    required String title,
    required String body,
  });

  Future<void> startTracking();
  Future<void> stopTracking();

  /// Publishes a live backend-authoritative telemetry payload.
  ///
  /// Host apps should prefer [getResolvedTelemetryPreview] and publish only
  /// previews that are explicitly marked as backend-authoritative by their
  /// integration layer. Display-only sources such as cached fallbacks, backend
  /// snapshots, and remote relay event locations are not valid for this raw
  /// publish path.
  Future<void> publishTelemetry(SdkTelemetryPayload payload);
  Future<TrackingPosition?> getCurrentPosition();
  Future<TrackingState> getTrackingState();
  Stream<TrackingPosition> watchPositions();
  Stream<TrackingState> watchTrackingState();

  Future<SosIncident> cancelSos();
  Future<SosCancellationResult> cancelSosAuthoritatively();
  Future<void> resolveSos();
  Future<SosState> acknowledgeSosSummary();
  Future<SosState> getSosState();

  /// Returns paginated SOS history for the authenticated user.
  ///
  /// [cursor] is the `nextCursor` from the previous page. [limit] defaults to 20
  /// and is capped at 100 by the backend.
  Future<SosHistoryPage> listSosHistory({String? cursor, int limit = 20});
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
    String language = 'en',
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

/// Optional capability implemented by SDK runtimes that can expose incident
/// progress directly from their repository-owned realtime lifecycle.
abstract interface class SosIncidentProgressProvider {
  Future<SosIncidentProgress?> getCurrentSosIncidentProgress();
  Stream<SosIncidentProgress?> get currentSosIncidentProgressStream;
}

/// Additive progress API for every [EixamConnectSdk] consumer.
///
/// Production runtimes use [SosIncidentProgressProvider]. Existing custom SDK
/// implementations retain source compatibility and receive a state-stream
/// fallback derived from the public incident model.
extension EixamConnectSdkIncidentProgress on EixamConnectSdk {
  Future<SosIncidentProgress?> getCurrentSosIncidentProgress() async {
    final sdk = this;
    if (sdk is SosIncidentProgressProvider) {
      return sdk.getCurrentSosIncidentProgress();
    }
    return (await getCurrentSosIncident())?.progress;
  }

  Stream<SosIncidentProgress?> get currentSosIncidentProgressStream {
    final sdk = this;
    if (sdk is SosIncidentProgressProvider) {
      return sdk.currentSosIncidentProgressStream;
    }
    return currentSosStateStream.asyncMap(
      (_) async => (await getCurrentSosIncident())?.progress,
    );
  }
}
