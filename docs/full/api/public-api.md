# Public API

Complete mirror of the current public `EixamConnectSdk` surface.

## Initialization and session
- `Future<void> initialize(EixamSdkConfig config)`
- `Future<void> setSession(EixamSession session)`
- `Future<void> clearSession()`
- `Future<EixamSession?> getCurrentSession()`
- `Future<EixamSession> refreshCanonicalIdentity()`

## Operational diagnostics and protection
- `Future<SdkOperationalDiagnostics> getOperationalDiagnostics()`
- `Stream<SdkOperationalDiagnostics> watchOperationalDiagnostics()`
- `Future<ProtectionReadinessReport> evaluateProtectionReadiness()`
- `Future<EnterProtectionModeResult> enterProtectionMode({ ProtectionModeOptions options = const ProtectionModeOptions(), })`
- `Future<ProtectionStatus> exitProtectionMode()`
- `Future<ProtectionStatus> getProtectionStatus()`
- `Stream<ProtectionStatus> watchProtectionStatus()`
- `Future<ProtectionDiagnostics> getProtectionDiagnostics()`
- `Stream<ProtectionDiagnostics> watchProtectionDiagnostics()`
- `Future<ProtectionStatus> rehydrateProtectionState()`
- `Future<FlushProtectionQueuesResult> flushProtectionQueues()`

## Local device runtime
- `Future<DeviceStatus> connectDevice({required String pairingCode})`
- `Future<void> disconnectDevice()`
- `Future<PreferredDevice?> get preferredDevice`
- `Stream<DeviceStatus> get deviceStatusStream`
- `Future<DeviceStatus> pairDevice({required String pairingCode})` _(legacy)_
- `Future<DeviceStatus> activateDevice({required String activationCode})`
- `Future<DeviceStatus> getDeviceStatus()`
- `Future<DeviceStatus> refreshDeviceStatus()`
- `Future<void> unpairDevice()` _(legacy)_
- `Stream<DeviceStatus> watchDeviceStatus()` _(legacy)_
- `Future<DeviceSosStatus> getDeviceSosStatus()`
- `Stream<DeviceSosStatus> watchDeviceSosStatus()`
- `Future<DeviceSosStatus> triggerDeviceSos()`
- `Future<DeviceSosStatus> confirmDeviceSos()`
- `Future<DeviceSosStatus> cancelDeviceSos()`
- `Future<DeviceSosStatus> acknowledgeDeviceSos()`
- `Future<void> sendInetOkToDevice()`
- `Future<void> sendInetLostToDevice()`
- `Future<void> sendPositionConfirmedToDevice()`
- `Future<void> sendSosAckRelayToDevice({required int nodeId})`
- `Future<void> sendShutdownToDevice()`
- `Future<BleNotificationNavigationRequest?> consumePendingBleNotificationNavigationRequest()`
- `Stream<BleNotificationNavigationRequest> watchBleNotificationNavigationRequests()`

## Backend device registry
- `Future<List<BackendRegisteredDevice>> listRegisteredDevices()`
- `Future<BackendRegisteredDevice> upsertRegisteredDevice({ required String hardwareId, required String firmwareVersion, required String hardwareModel, required DateTime pairedAt, })`
- `Future<void> deleteRegisteredDevice(String deviceId)`

## SOS
- `Future<SosIncident> triggerSos(SosTriggerPayload payload)`
- `Future<SosIncident?> getCurrentSosIncident()`
- `Stream<SosState> get currentSosStateStream`
- `Stream<EixamSdkEvent> get lastSosEventStream`
- `Future<SosIncident> cancelSos()`
- `Future<SosState> getSosState()`
- `Stream<SosState> watchSosState()` _(legacy)_

## Contacts
- `Future<EmergencyContact> createEmergencyContact({ required String name, required String phone, required String email, int priority = 1, })`
- `Future<void> deleteEmergencyContact(String contactId)`
- `Future<List<EmergencyContact>> listEmergencyContacts()`
- `Stream<List<EmergencyContact>> watchEmergencyContacts()`
- `Future<EmergencyContact> addEmergencyContact({ required String name, required String phone, required String email, int priority = 1, })` _(legacy)_
- `Future<EmergencyContact> updateEmergencyContact(EmergencyContact contact)`
- `Future<void> removeEmergencyContact(String contactId)` _(legacy)_

## Permissions and notifications
- `Future<PermissionState> getPermissionState()`
- `Future<PermissionState> requestLocationPermission()`
- `Future<PermissionState> requestNotificationPermission()`
- `Future<PermissionState> requestBluetoothPermission()`
- `Future<void> initializeNotifications()`
- `Future<void> showLocalNotification({ required String title, required String body, })`

## Guided rescue
- `Future<GuidedRescueState> getGuidedRescueState()`
- `Stream<GuidedRescueState> watchGuidedRescueState()`
- `Future<GuidedRescueState> setGuidedRescueSession({ required int targetNodeId, required int rescueNodeId, })`
- `Future<void> clearGuidedRescueSession()`
- `Future<void> requestGuidedRescuePosition()`
- `Future<void> acknowledgeGuidedRescueSos()`
- `Future<void> enableGuidedRescueBuzzer()`
- `Future<void> disableGuidedRescueBuzzer()`
- `Future<void> requestGuidedRescueStatus()`

## Tracking and telemetry
- `Future<void> startTracking()`
- `Future<void> stopTracking()`
- `Future<void> publishTelemetry(SdkTelemetryPayload payload)`
- `Future<TrackingPosition?> getCurrentPosition()`
- `Future<TrackingState> getTrackingState()`
- `Stream<TrackingPosition> watchPositions()`
- `Stream<TrackingState> watchTrackingState()`

## Death Man
- `Future<DeathManPlan> scheduleDeathMan({ required DateTime expectedReturnAt, Duration gracePeriod = const Duration(minutes: 30), Duration checkInWindow = const Duration(minutes: 10), bool autoTriggerSos = true, })`
- `Future<DeathManPlan?> getActiveDeathManPlan()`
- `Future<void> confirmDeathManCheckIn(String planId)`
- `Future<void> cancelDeathMan(String planId)`
- `Stream<DeathManPlan> watchDeathManPlans()`

## Events and realtime
- `Stream<EixamSdkEvent> watchEvents()`
- `Future<RealtimeConnectionState> getRealtimeConnectionState()`
- `Future<RealtimeEvent?> getLastRealtimeEvent()`
- `Stream<RealtimeConnectionState> watchRealtimeConnectionState()`
- `Stream<RealtimeEvent> watchRealtimeEvents()`
