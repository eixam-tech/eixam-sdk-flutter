# Public API

This page documents the recommended partner-facing SDK methods.

Deprecated and compatibility methods are intentionally omitted from the partner path. If you are migrating an older host app, use the full/internal docs for those surfaces.

## Bootstrap

### `EixamConnectSdk.bootstrap(...)`

Purpose:
- creates the SDK
- resolves the selected environment
- validates the bootstrap config
- applies the initial signed session when provided

Returns:
- `Future<EixamConnectSdk>`

Most-used inputs:
- `appId`
- `environment`
- `initialSession`

Signed-session reminder:
- the partner backend owns the app secret and signs the session
- the mobile app receives `appId`, `externalUserId`, and `userHash`
- the same identity is reused across HTTP and MQTT/runtime transport
- HTTP keeps `Authorization: Bearer <userHash>`
- MQTT uses `username = sdk:<appId>:<externalUserId>` and `password = <userHash>`

```dart
final sdk = await EixamConnectSdk.bootstrap(
  const EixamBootstrapConfig(
    appId: 'partner-app',
    environment: EixamEnvironment.sandbox,
    initialSession: EixamSession.signed(
      appId: 'partner-app',
      externalUserId: 'partner-user-123',
      userHash: 'signed-session-hash',
    ),
  ),
);

final session = await sdk.getCurrentSession();
debugPrint('session user=${session?.externalUserId}');
```

Transport note:
- `websocketUrl` naming stays stable for now
- the configured broker URI may still be `ssl://`, `tls://`, `tcp://`, `ws://`, or `wss://`

## Diagnostics

### `getOperationalDiagnostics()`

Purpose:
- returns the latest operational runtime snapshot for session, transport, bridge, and SOS rehydration state

Returns:
- [`SdkOperationalDiagnostics`](model-reference.md#sdkoperationaldiagnostics)

Common fields to inspect:
- `connectionState`
- `telemetryPublishTopic`
- `sosEventTopics`
- `sosRehydrationNote`
- `bridge.lastDecision`
- `bridge.pendingSos`
- `bridge.pendingTelemetry`

```dart
final diagnostics = await sdk.getOperationalDiagnostics();
debugPrint('mqtt=${diagnostics.connectionState.name}');
debugPrint('telTopic=${diagnostics.telemetryPublishTopic}');
debugPrint('lastDecision=${diagnostics.bridge.lastDecision}');
debugPrint('pendingSos=${diagnostics.bridge.pendingSos != null}');
```

### `watchOperationalDiagnostics()`

Purpose:
- streams operational changes after bootstrap, session updates, reconnects, and bridge/runtime changes

Returns:
- `Stream<`[`SdkOperationalDiagnostics`](model-reference.md#sdkoperationaldiagnostics)`>`

Common fields to inspect:
- `connectionState`
- `bridge.lastDecision`
- `bridge.lastBleTelemetryEventSummary`
- `bridge.lastBleSosEventSummary`

```dart
final sub = sdk.watchOperationalDiagnostics().listen((diagnostics) {
  debugPrint('mqtt=${diagnostics.connectionState.name}');
  debugPrint('bridge=${diagnostics.bridge.lastDecision}');
});
```

## Device Lifecycle

### `connectDevice(...)`

Purpose:
- pairs or reconnects the partner-selected device and returns the resulting runtime status

Returns:
- [`DeviceStatus`](model-reference.md#devicestatus)

Common fields to inspect:
- `deviceId`
- `lifecycleState`
- `paired`
- `activated`
- `connected`
- `isReadyForSafety`

```dart
final status = await sdk.connectDevice(pairingCode: '123456');
debugPrint('device=${status.deviceId}');
debugPrint('lifecycle=${status.lifecycleState.name}');
debugPrint('ready=${status.isReadyForSafety}');
```

### `getDeviceStatus()`

Purpose:
- reads the latest cached device runtime snapshot without starting a new pairing flow

Returns:
- [`DeviceStatus`](model-reference.md#devicestatus)

Common fields to inspect:
- `deviceId`
- `connected`
- `lastSeen`
- `firmwareVersion`
- `provisioningError`

```dart
final status = await sdk.getDeviceStatus();
debugPrint('connected=${status.connected}');
debugPrint('lastSeen=${status.lastSeen}');
debugPrint('firmware=${status.firmwareVersion}');
```

### `deviceStatusStream`

Purpose:
- streams lifecycle changes while the device connects, activates, disconnects, or recovers

Returns:
- `Stream<`[`DeviceStatus`](model-reference.md#devicestatus)`>`

Common fields to inspect:
- `lifecycleState`
- `connected`
- `signalQuality`
- `approximateBatteryPercentage`

```dart
final sub = sdk.deviceStatusStream.listen((status) {
  debugPrint('lifecycle=${status.lifecycleState.name}');
  debugPrint('connected=${status.connected}');
  debugPrint('battery=${status.approximateBatteryPercentage}');
});
```

### `getDeviceSosStatus()`

Purpose:
- returns the current device-side SOS state tracked by the SDK runtime

Returns:
- [`DeviceSosStatus`](model-reference.md#devicesosstatus)

Common fields to inspect:
- `state`
- `lastEvent`
- `transitionSource`
- `countdownRemainingSeconds`
- `updatedAt`

```dart
final status = await sdk.getDeviceSosStatus();
debugPrint('state=${status.state.name}');
debugPrint('event=${status.lastEvent}');
debugPrint('countdown=${status.countdownRemainingSeconds}');
```

## SOS

### `triggerSos(...)`

Purpose:
- creates an app-originated SOS incident using the current signed session and operational runtime

Returns:
- [`SosIncident`](model-reference.md#sosincident)

Common fields to inspect:
- `id`
- `state`
- `createdAt`
- `triggerSource`
- `message`

```dart
final incident = await sdk.triggerSos(
  const SosTriggerPayload(
    message: 'Need assistance',
    triggerSource: 'button_ui',
  ),
);

debugPrint('incident=${incident.id}');
debugPrint('state=${incident.state.name}');
```

### `getCurrentSosIncident()`

Purpose:
- returns the latest known active or recently settled SOS incident after runtime rehydration

Returns:
- `Future<`[`SosIncident`](model-reference.md#sosincident)`?>`

Common fields to inspect:
- `id`
- `state`
- `createdAt`
- `positionSnapshot`

```dart
final incident = await sdk.getCurrentSosIncident();
if (incident != null) {
  debugPrint('incident=${incident.id}');
  debugPrint('state=${incident.state.name}');
  debugPrint('hasPosition=${incident.positionSnapshot != null}');
}
```

### `getSosState()`

Purpose:
- returns the current SOS lifecycle state when your UI needs a small status check

Returns:
- `Future<SosState>`

Common values to handle:
- `idle`
- `sent`
- `acknowledged`
- `cancelRequested`
- `cancelled`

```dart
final state = await sdk.getSosState();
debugPrint('sosState=${state.name}');
```

## Contacts

### `listEmergencyContacts()`

Purpose:
- loads the current backend-synced emergency contacts for the signed user

Returns:
- `Future<List<`[`EmergencyContact`](model-reference.md#emergencycontact)`>>`

Common fields to inspect:
- `id`
- `name`
- `phone`
- `priority`

```dart
final contacts = await sdk.listEmergencyContacts();
for (final contact in contacts) {
  debugPrint('${contact.priority}: ${contact.name} ${contact.phone}');
}
```

### `createEmergencyContact(...)`

Purpose:
- creates a new emergency contact and returns the saved record

Returns:
- [`EmergencyContact`](model-reference.md#emergencycontact)

Common fields to inspect:
- `id`
- `name`
- `phone`
- `priority`
- `updatedAt`

```dart
final contact = await sdk.createEmergencyContact(
  name: 'Mountain Rescue Desk',
  phone: '+34600000000',
  email: 'rescue@example.com',
  priority: 1,
);

debugPrint('contact=${contact.id}');
debugPrint('priority=${contact.priority}');
```

### `updateEmergencyContact(...)`

Purpose:
- updates an existing contact and returns the saved record

Returns:
- [`EmergencyContact`](model-reference.md#emergencycontact)

Common fields to inspect:
- `id`
- `name`
- `phone`
- `priority`
- `updatedAt`

```dart
final current = (await sdk.listEmergencyContacts()).first;
final updated = await sdk.updateEmergencyContact(
  current.copyWith(name: 'Mountain Rescue 24/7'),
);

debugPrint('contact=${updated.id}');
debugPrint('name=${updated.name}');
debugPrint('updatedAt=${updated.updatedAt}');
```

## Permissions

### `getPermissionState()`

Purpose:
- returns one aggregated snapshot for location, notifications, Bluetooth, and Bluetooth service availability

Returns:
- [`PermissionState`](model-reference.md#permissionstate)

Common fields to inspect:
- `location`
- `notifications`
- `bluetooth`
- `bluetoothEnabled`
- `canUseBluetooth`

```dart
final state = await sdk.getPermissionState();
debugPrint('location=${state.location.name}');
debugPrint('notifications=${state.notifications.name}');
debugPrint('bluetoothReady=${state.canUseBluetooth}');
```

## Protection Mode

Background continuity is far stronger on Android when Protection Mode/native foreground service owns the BLE transport. Plain Flutter-owned BLE provides no guaranteed full background runtime.

### `getProtectionStatus()`

Purpose:
- returns the current runtime status for armed/degraded/off state and native BLE ownership

Returns:
- [`ProtectionStatus`](model-reference.md#protectionstatus)

Common fields to inspect:
- `modeState`
- `runtimeState`
- `bleOwner`
- `protectedDeviceId`
- `serviceBleConnected`
- `serviceBleReady`
- `degradationReason`

```dart
final status = await sdk.getProtectionStatus();
debugPrint('mode=${status.modeState.name}');
debugPrint('runtime=${status.runtimeState.name}');
debugPrint('owner=${status.bleOwner.name}');
debugPrint('protectedDevice=${status.protectedDeviceId}');
```

### `getProtectionDiagnostics()`

Purpose:
- returns the latest native/runtime diagnostics for reconnects, wake events, queueing, and command routing

Returns:
- [`ProtectionDiagnostics`](model-reference.md#protectiondiagnostics)

Common fields to inspect:
- `lastWakeReason`
- `reconnectAttemptCount`
- `lastReconnectAttemptAt`
- `lastCommandRoute`
- `lastCommandResult`
- `lastCommandError`

```dart
final diagnostics = await sdk.getProtectionDiagnostics();
debugPrint('wake=${diagnostics.lastWakeReason}');
debugPrint('reconnects=${diagnostics.reconnectAttemptCount}');
debugPrint('lastCommandRoute=${diagnostics.lastCommandRoute}');
```

## Backend Device Registry

### Paired-device sync logic

- after a known device is paired/connected and the signed-session identity is ready, the SDK/runtime may attempt backend paired-device sync.
- the validation app registry card is a status/retry/debug surface, not the intended primary manual flow.
- automatic sync uses `hardware_id`, `firmware_version`, `hardware_model`, and `paired_at`.
- automatic sync is safe only when a canonical backend-compatible hardware id can be resolved.


### `listRegisteredDevices()`

Purpose:
- returns backend device records associated with the signed user

Returns:
- `Future<List<`[`BackendRegisteredDevice`](model-reference.md#backendregistereddevice)`>>`

Common fields to inspect:
- `id`
- `hardwareId`
- `firmwareVersion`
- `hardwareModel`
- `pairedAt`

```dart
final devices = await sdk.listRegisteredDevices();
for (final device in devices) {
  debugPrint('${device.hardwareId} ${device.firmwareVersion}');
}
```

## Omitted from the partner path

The partner site intentionally omits:
- deprecated compatibility methods kept only for migration
- internal validation-first capability groups such as Guided Rescue Phase 1
- low-level device-control examples that are not part of the recommended onboarding path
