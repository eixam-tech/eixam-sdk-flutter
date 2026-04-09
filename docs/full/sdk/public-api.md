# Public API

This page documents the current public `EixamConnectSdk` surface used by host apps.

The sections below focus on the methods partners inspect most often in practice. Legacy compatibility methods remain documented in the appendix instead of the main partner path.

## Bootstrap

### `EixamConnectSdk.bootstrap(...)`

Purpose:
- creates the SDK
- resolves the selected environment
- validates the bootstrap config
- applies the initial signed session when provided

Returns:
- `Future<EixamConnectSdk>`

Signed-session reminder:
- backend-owned app secret only
- mobile app receives a signed session from backend
- the same signed identity is reused for HTTP and MQTT/runtime transport
- `websocketUrl` naming stays stable even when the actual broker URI is not websocket-based

## Diagnostics

### `getOperationalDiagnostics()`

Purpose:
- returns the latest operational runtime snapshot for session, transport, bridge, and SOS rehydration state

Returns:
- [`SdkOperationalDiagnostics`](model-reference.md#sdkoperationaldiagnostics)

Common fields:
- `connectionState`
- `telemetryPublishTopic`
- `sosEventTopics`
- `sosRehydrationNote`
- `bridge.lastDecision`
- `bridge.pendingSos`
- `bridge.pendingTelemetry`

### `watchOperationalDiagnostics()`

Purpose:
- streams operational changes after bootstrap, session updates, reconnects, and bridge/runtime changes

Returns:
- `Stream<`[`SdkOperationalDiagnostics`](model-reference.md#sdkoperationaldiagnostics)`>`

## Device Lifecycle

### `connectDevice(...)`

Purpose:
- pairs or reconnects the selected device and returns the resulting runtime status

Returns:
- [`DeviceStatus`](model-reference.md#devicestatus)

Common fields:
- `deviceId`
- `lifecycleState`
- `paired`
- `activated`
- `connected`
- `isReadyForSafety`

### `getDeviceStatus()`

Returns:
- [`DeviceStatus`](model-reference.md#devicestatus)

Common fields:
- `connected`
- `lastSeen`
- `firmwareVersion`
- `provisioningError`

### `deviceStatusStream`

Returns:
- `Stream<`[`DeviceStatus`](model-reference.md#devicestatus)`>`

Common fields:
- `lifecycleState`
- `connected`
- `signalQuality`
- `approximateBatteryPercentage`

### `getDeviceSosStatus()`

Returns:
- [`DeviceSosStatus`](model-reference.md#devicesosstatus)

Common fields:
- `state`
- `lastEvent`
- `transitionSource`
- `countdownRemainingSeconds`

## SOS

### `triggerSos(...)`

Purpose:
- creates an app-originated SOS incident using the current signed session and operational runtime

Returns:
- [`SosIncident`](model-reference.md#sosincident)

Common fields:
- `id`
- `state`
- `createdAt`
- `triggerSource`
- `message`

### `getCurrentSosIncident()`

Returns:
- `Future<`[`SosIncident`](model-reference.md#sosincident)`?>`

Common fields:
- `id`
- `state`
- `createdAt`
- `positionSnapshot`

### `getSosState()`

Returns:
- `Future<SosState>`

Common values:
- `idle`
- `sent`
- `acknowledged`
- `cancelRequested`
- `cancelled`

## Contacts

### `listEmergencyContacts()`

Returns:
- `Future<List<`[`EmergencyContact`](model-reference.md#emergencycontact)`>>`

Common fields:
- `id`
- `name`
- `phone`
- `priority`

### `createEmergencyContact(...)`

Returns:
- [`EmergencyContact`](model-reference.md#emergencycontact)

Common fields:
- `id`
- `name`
- `phone`
- `priority`
- `updatedAt`

### `updateEmergencyContact(...)`

Returns:
- [`EmergencyContact`](model-reference.md#emergencycontact)

Common fields:
- `id`
- `name`
- `phone`
- `priority`
- `updatedAt`

## Permissions

### `getPermissionState()`

Returns:
- [`PermissionState`](model-reference.md#permissionstate)

Common fields:
- `location`
- `notifications`
- `bluetooth`
- `bluetoothEnabled`
- `canUseBluetooth`

## Protection Mode

### `getProtectionStatus()`

Returns:
- [`ProtectionStatus`](model-reference.md#protectionstatus)

Common fields:
- `modeState`
- `runtimeState`
- `bleOwner`
- `protectedDeviceId`
- `serviceBleConnected`
- `serviceBleReady`
- `degradationReason`

### `getProtectionDiagnostics()`

Returns:
- [`ProtectionDiagnostics`](model-reference.md#protectiondiagnostics)

Common fields:
- `lastWakeReason`
- `reconnectAttemptCount`
- `lastReconnectAttemptAt`
- `lastCommandRoute`
- `lastCommandResult`
- `lastCommandError`

## Backend Device Registry

### `listRegisteredDevices()`

Returns:
- `Future<List<`[`BackendRegisteredDevice`](model-reference.md#backendregistereddevice)`>>`

Common fields:
- `id`
- `hardwareId`
- `firmwareVersion`
- `hardwareModel`
- `pairedAt`

## Legacy / compatibility appendix

The following public methods still exist for migration or internal validation, but they are intentionally excluded from the partner-facing path:

- `initialize(...)`
- `pairDevice(...)`
- `unpairDevice()`
- `watchDeviceStatus()`
- `watchSosState()`
- `addEmergencyContact(...)`
- `removeEmergencyContact(...)`

The rest of the full site may still mention these methods where migration context matters.
