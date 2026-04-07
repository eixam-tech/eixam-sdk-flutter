# API Examples

Short usage example for each public SDK method currently exposed in the partner path.

> Guided Rescue is intentionally excluded from the partner site navigation and remains available in the full site only.

## Initialization and session

### `initialize`

**Signature**: `Future<void> initialize(EixamSdkConfig config)`

```dart
await sdk.initialize(const EixamSdkConfig());
```

### `setSession`

**Signature**: `Future<void> setSession(EixamSession session)`

```dart
await sdk.setSession(const EixamSession.signed(appId: 'partner-app', externalUserId: 'user-123', userHash: 'signed-hash'));
```

### `clearSession`

**Signature**: `Future<void> clearSession()`

```dart
await sdk.clearSession();
```

### `getCurrentSession`

**Signature**: `Future<EixamSession?> getCurrentSession()`

```dart
final session = await sdk.getCurrentSession();
```

### `refreshCanonicalIdentity`

**Signature**: `Future<EixamSession> refreshCanonicalIdentity()`

```dart
final canonical = await sdk.refreshCanonicalIdentity();
```

## Operational diagnostics and protection

### `getOperationalDiagnostics`

**Signature**: `Future<SdkOperationalDiagnostics> getOperationalDiagnostics()`

```dart
final diagnostics = await sdk.getOperationalDiagnostics();
```

### `watchOperationalDiagnostics`

**Signature**: `Stream<SdkOperationalDiagnostics> watchOperationalDiagnostics()`

```dart
sdk.watchOperationalDiagnostics().listen((d) { /* render diagnostics */ });
```

### `evaluateProtectionReadiness`

**Signature**: `Future<ProtectionReadinessReport> evaluateProtectionReadiness()`

```dart
final report = await sdk.evaluateProtectionReadiness();
```

### `enterProtectionMode`

**Signature**: `Future<EnterProtectionModeResult> enterProtectionMode({ ProtectionModeOptions options = const ProtectionModeOptions(), })`

```dart
final result = await sdk.enterProtectionMode();
```

### `exitProtectionMode`

**Signature**: `Future<ProtectionStatus> exitProtectionMode()`

```dart
final status = await sdk.exitProtectionMode();
```

### `getProtectionStatus`

**Signature**: `Future<ProtectionStatus> getProtectionStatus()`

```dart
final status = await sdk.getProtectionStatus();
```

### `watchProtectionStatus`

**Signature**: `Stream<ProtectionStatus> watchProtectionStatus()`

```dart
sdk.watchProtectionStatus().listen((status) { /* update UI */ });
```

### `getProtectionDiagnostics`

**Signature**: `Future<ProtectionDiagnostics> getProtectionDiagnostics()`

```dart
final diagnostics = await sdk.getProtectionDiagnostics();
```

### `watchProtectionDiagnostics`

**Signature**: `Stream<ProtectionDiagnostics> watchProtectionDiagnostics()`

```dart
sdk.watchProtectionDiagnostics().listen((d) { /* update UI */ });
```

### `rehydrateProtectionState`

**Signature**: `Future<ProtectionStatus> rehydrateProtectionState()`

```dart
final status = await sdk.rehydrateProtectionState();
```

### `flushProtectionQueues`

**Signature**: `Future<FlushProtectionQueuesResult> flushProtectionQueues()`

```dart
final result = await sdk.flushProtectionQueues();
```

## SOS

### `triggerSos`

**Signature**: `Future<SosIncident> triggerSos(SosTriggerPayload payload)`

```dart
await sdk.triggerSos(const SosTriggerPayload(message: 'Need help', triggerSource: 'button_ui'));
```

### `getCurrentSosIncident`

**Signature**: `Future<SosIncident?> getCurrentSosIncident()`

```dart
final incident = await sdk.getCurrentSosIncident();
```

### `currentSosStateStream`

**Signature**: `Stream<SosState> get currentSosStateStream`

```dart
sdk.currentSosStateStream.listen((state) { /* render SOS state */ });
```

### `lastSosEventStream`

**Signature**: `Stream<EixamSdkEvent> get lastSosEventStream`

```dart
sdk.lastSosEventStream.listen((event) { /* inspect last event */ });
```

### `cancelSos`

**Signature**: `Future<SosIncident> cancelSos()`

```dart
await sdk.cancelSos();
```

### `getSosState`

**Signature**: `Future<SosState> getSosState()`

```dart
final state = await sdk.getSosState();
```

### `watchSosState`

**Signature**: `Stream<SosState> watchSosState()`

_Legacy API. Prefer the replacement in the same section._

```dart
sdk.watchSosState().listen((state) { /* legacy stream */ });
```

## Contacts

### `createEmergencyContact`

**Signature**: `Future<EmergencyContact> createEmergencyContact({ required String name, required String phone, required String email, int priority = 1, })`

```dart
await sdk.createEmergencyContact(name: 'Alice', phone: '+34123456789', email: 'alice@example.com');
```

### `deleteEmergencyContact`

**Signature**: `Future<void> deleteEmergencyContact(String contactId)`

```dart
await sdk.deleteEmergencyContact('contact-id');
```

### `listEmergencyContacts`

**Signature**: `Future<List<EmergencyContact>> listEmergencyContacts()`

```dart
final contacts = await sdk.listEmergencyContacts();
```

### `watchEmergencyContacts`

**Signature**: `Stream<List<EmergencyContact>> watchEmergencyContacts()`

```dart
sdk.watchEmergencyContacts().listen((contacts) { /* render contacts */ });
```

### `addEmergencyContact`

**Signature**: `Future<EmergencyContact> addEmergencyContact({ required String name, required String phone, required String email, int priority = 1, })`

_Legacy API. Prefer the replacement in the same section._

```dart
await sdk.addEmergencyContact(name: 'Alice', phone: '+34123456789', email: 'alice@example.com');
```

### `updateEmergencyContact`

**Signature**: `Future<EmergencyContact> updateEmergencyContact(EmergencyContact contact)`

```dart
await sdk.updateEmergencyContact(contact);
```

### `removeEmergencyContact`

**Signature**: `Future<void> removeEmergencyContact(String contactId)`

_Legacy API. Prefer the replacement in the same section._

```dart
await sdk.removeEmergencyContact('contact-id');
```

## Permissions and notifications

### `getPermissionState`

**Signature**: `Future<PermissionState> getPermissionState()`

```dart
final permissions = await sdk.getPermissionState();
```

### `requestLocationPermission`

**Signature**: `Future<PermissionState> requestLocationPermission()`

```dart
await sdk.requestLocationPermission();
```

### `requestNotificationPermission`

**Signature**: `Future<PermissionState> requestNotificationPermission()`

```dart
await sdk.requestNotificationPermission();
```

### `requestBluetoothPermission`

**Signature**: `Future<PermissionState> requestBluetoothPermission()`

```dart
await sdk.requestBluetoothPermission();
```

### `initializeNotifications`

**Signature**: `Future<void> initializeNotifications()`

```dart
await sdk.initializeNotifications();
```

### `showLocalNotification`

**Signature**: `Future<void> showLocalNotification({ required String title, required String body, })`

```dart
await sdk.showLocalNotification(title: 'EIXAM', body: 'Device connected');
```

## Local device runtime

### `connectDevice`

**Signature**: `Future<DeviceStatus> connectDevice({required String pairingCode})`

```dart
final status = await sdk.connectDevice(pairingCode: 'PAIR-1234');
```

### `disconnectDevice`

**Signature**: `Future<void> disconnectDevice()`

```dart
await sdk.disconnectDevice();
```

### `preferredDevice`

**Signature**: `Future<PreferredDevice?> get preferredDevice`

```dart
final device = await sdk.preferredDevice;
```

### `deviceStatusStream`

**Signature**: `Stream<DeviceStatus> get deviceStatusStream`

```dart
sdk.deviceStatusStream.listen((status) { /* render BLE/runtime state */ });
```

### `pairDevice`

**Signature**: `Future<DeviceStatus> pairDevice({required String pairingCode})`

_Legacy API. Prefer the replacement in the same section._

```dart
final status = await sdk.pairDevice(pairingCode: 'PAIR-1234');
```

### `activateDevice`

**Signature**: `Future<DeviceStatus> activateDevice({required String activationCode})`

```dart
final status = await sdk.activateDevice(activationCode: 'ACT-1234');
```

### `getDeviceStatus`

**Signature**: `Future<DeviceStatus> getDeviceStatus()`

```dart
final status = await sdk.getDeviceStatus();
```

### `refreshDeviceStatus`

**Signature**: `Future<DeviceStatus> refreshDeviceStatus()`

```dart
final status = await sdk.refreshDeviceStatus();
```

### `unpairDevice`

**Signature**: `Future<void> unpairDevice()`

_Legacy API. Prefer the replacement in the same section._

```dart
await sdk.unpairDevice();
```

### `watchDeviceStatus`

**Signature**: `Stream<DeviceStatus> watchDeviceStatus()`

_Legacy API. Prefer the replacement in the same section._

```dart
sdk.watchDeviceStatus().listen((status) { /* legacy status stream */ });
```

### `getDeviceSosStatus`

**Signature**: `Future<DeviceSosStatus> getDeviceSosStatus()`

```dart
final sos = await sdk.getDeviceSosStatus();
```

### `watchDeviceSosStatus`

**Signature**: `Stream<DeviceSosStatus> watchDeviceSosStatus()`

```dart
sdk.watchDeviceSosStatus().listen((sos) { /* render device SOS state */ });
```

### `triggerDeviceSos`

**Signature**: `Future<DeviceSosStatus> triggerDeviceSos()`

```dart
await sdk.triggerDeviceSos();
```

### `confirmDeviceSos`

**Signature**: `Future<DeviceSosStatus> confirmDeviceSos()`

```dart
await sdk.confirmDeviceSos();
```

### `cancelDeviceSos`

**Signature**: `Future<DeviceSosStatus> cancelDeviceSos()`

```dart
await sdk.cancelDeviceSos();
```

### `acknowledgeDeviceSos`

**Signature**: `Future<DeviceSosStatus> acknowledgeDeviceSos()`

```dart
await sdk.acknowledgeDeviceSos();
```

### `sendInetOkToDevice`

**Signature**: `Future<void> sendInetOkToDevice()`

```dart
await sdk.sendInetOkToDevice();
```

### `sendInetLostToDevice`

**Signature**: `Future<void> sendInetLostToDevice()`

```dart
await sdk.sendInetLostToDevice();
```

### `sendPositionConfirmedToDevice`

**Signature**: `Future<void> sendPositionConfirmedToDevice()`

```dart
await sdk.sendPositionConfirmedToDevice();
```

### `sendSosAckRelayToDevice`

**Signature**: `Future<void> sendSosAckRelayToDevice({required int nodeId})`

```dart
await sdk.sendSosAckRelayToDevice(nodeId: 42);
```

### `sendShutdownToDevice`

**Signature**: `Future<void> sendShutdownToDevice()`

```dart
await sdk.sendShutdownToDevice();
```

### `consumePendingBleNotificationNavigationRequest`

**Signature**: `Future<BleNotificationNavigationRequest?> consumePendingBleNotificationNavigationRequest()`

```dart
final request = await sdk.consumePendingBleNotificationNavigationRequest();
```

### `watchBleNotificationNavigationRequests`

**Signature**: `Stream<BleNotificationNavigationRequest> watchBleNotificationNavigationRequests()`

```dart
sdk.watchBleNotificationNavigationRequests().listen((request) { /* navigate */ });
```

## Backend device registry

### `listRegisteredDevices`

**Signature**: `Future<List<BackendRegisteredDevice>> listRegisteredDevices()`

```dart
final devices = await sdk.listRegisteredDevices();
```

### `upsertRegisteredDevice`

**Signature**: `Future<BackendRegisteredDevice> upsertRegisteredDevice({ required String hardwareId, required String firmwareVersion, required String hardwareModel, required DateTime pairedAt, })`

```dart
await sdk.upsertRegisteredDevice(hardwareId: 'hw-1', firmwareVersion: '1.2.3', hardwareModel: 'EIXAM R1', pairedAt: DateTime.now().toUtc());
```

### `deleteRegisteredDevice`

**Signature**: `Future<void> deleteRegisteredDevice(String deviceId)`

```dart
await sdk.deleteRegisteredDevice('device-id');
```

## Tracking and telemetry

### `startTracking`

**Signature**: `Future<void> startTracking()`

```dart
await sdk.startTracking();
```

### `stopTracking`

**Signature**: `Future<void> stopTracking()`

```dart
await sdk.stopTracking();
```

### `publishTelemetry`

**Signature**: `Future<void> publishTelemetry(SdkTelemetryPayload payload)`

```dart
await sdk.publishTelemetry(SdkTelemetryPayload(timestamp: DateTime.now().toUtc(), latitude: 41.38, longitude: 2.17, altitude: 8, deviceId: 'device-1'));
```

### `getCurrentPosition`

**Signature**: `Future<TrackingPosition?> getCurrentPosition()`

```dart
final position = await sdk.getCurrentPosition();
```

### `getTrackingState`

**Signature**: `Future<TrackingState> getTrackingState()`

```dart
final state = await sdk.getTrackingState();
```

### `watchPositions`

**Signature**: `Stream<TrackingPosition> watchPositions()`

```dart
sdk.watchPositions().listen((position) { /* render position */ });
```

### `watchTrackingState`

**Signature**: `Stream<TrackingState> watchTrackingState()`

```dart
sdk.watchTrackingState().listen((state) { /* render tracking state */ });
```

## Death Man

### `scheduleDeathMan`

**Signature**: `Future<DeathManPlan> scheduleDeathMan({ required DateTime expectedReturnAt, Duration gracePeriod = const Duration(minutes: 30), Duration checkInWindow = const Duration(minutes: 10), bool autoTriggerSos = true, })`

```dart
await sdk.scheduleDeathMan(expectedReturnAt: DateTime.now().add(const Duration(hours: 4)));
```

### `getActiveDeathManPlan`

**Signature**: `Future<DeathManPlan?> getActiveDeathManPlan()`

```dart
final plan = await sdk.getActiveDeathManPlan();
```

### `confirmDeathManCheckIn`

**Signature**: `Future<void> confirmDeathManCheckIn(String planId)`

```dart
await sdk.confirmDeathManCheckIn('plan-id');
```

### `cancelDeathMan`

**Signature**: `Future<void> cancelDeathMan(String planId)`

```dart
await sdk.cancelDeathMan('plan-id');
```

### `watchDeathManPlans`

**Signature**: `Stream<DeathManPlan> watchDeathManPlans()`

```dart
sdk.watchDeathManPlans().listen((plan) { /* render plan */ });
```

## Events and realtime

### `watchEvents`

**Signature**: `Stream<EixamSdkEvent> watchEvents()`

```dart
sdk.watchEvents().listen((event) { /* inspect SDK events */ });
```

### `getRealtimeConnectionState`

**Signature**: `Future<RealtimeConnectionState> getRealtimeConnectionState()`

```dart
final state = await sdk.getRealtimeConnectionState();
```

### `getLastRealtimeEvent`

**Signature**: `Future<RealtimeEvent?> getLastRealtimeEvent()`

```dart
final event = await sdk.getLastRealtimeEvent();
```

### `watchRealtimeConnectionState`

**Signature**: `Stream<RealtimeConnectionState> watchRealtimeConnectionState()`

```dart
sdk.watchRealtimeConnectionState().listen((state) { /* render transport state */ });
```

### `watchRealtimeEvents`

**Signature**: `Stream<RealtimeEvent> watchRealtimeEvents()`

```dart
sdk.watchRealtimeEvents().listen((event) { /* inspect transport events */ });
```
