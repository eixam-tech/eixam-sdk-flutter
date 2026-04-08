# Model Reference

This page summarizes the return types partner apps most often inspect.

## `SdkOperationalDiagnostics`

Purpose:
- snapshot of operational runtime health after bootstrap and session setup

Common fields:
- `connectionState`: MQTT/realtime transport state
- `session`: current signed session when present
- `telemetryPublishTopic`: operational telemetry topic the SDK is using
- `sosEventTopics`: SOS event topics currently bound for the signed user
- `sosRehydrationNote`: explains fallback or rehydration behavior after startup
- `bridge.lastDecision`: latest bridge/runtime decision worth surfacing in diagnostics
- `bridge.pendingSos`: queued SOS handoff details when an SOS is buffered
- `bridge.pendingTelemetry`: queued telemetry payload details when telemetry is buffered

## `DeviceStatus`

Purpose:
- high-level runtime view of the connected or remembered EIXAM device

Common fields:
- `deviceId`: stable device identifier used by the SDK
- `lifecycleState`: `unpaired`, `paired`, `activating`, `ready`, or `error`
- `paired`
- `activated`
- `connected`
- `isReadyForSafety`: most useful single readiness flag for host UI
- `approximateBatteryPercentage`
- `signalQuality`
- `firmwareVersion`
- `provisioningError`

## `DeviceSosStatus`

Purpose:
- device-side SOS state maintained by the runtime

Common fields:
- `state`: `inactive`, `preConfirm`, `active`, `acknowledged`, or `resolved`
- `lastEvent`: most recent runtime explanation
- `transitionSource`: where the current state came from
- `updatedAt`
- `countdownRemainingSeconds`: useful during pre-confirm countdowns
- `lastPacketAt`: last BLE SOS packet time when relevant
- `decoderNote`: runtime note when packet interpretation matters

## `EmergencyContact`

Purpose:
- backend-synced emergency contact record

Common fields:
- `id`
- `name`
- `phone`
- `email`
- `priority`
- `updatedAt`

## `SosIncident`

Purpose:
- app-originated SOS incident tracked by the SDK runtime

Common fields:
- `id`
- `state`
- `createdAt`
- `triggerSource`
- `message`
- `positionSnapshot`

## `PermissionState`

Purpose:
- aggregated permission snapshot for partner UI and gating logic

Common fields:
- `location`
- `notifications`
- `bluetooth`
- `bluetoothEnabled`
- `hasLocationAccess`
- `hasNotificationAccess`
- `canUseBluetooth`

## `ProtectionStatus`

Purpose:
- current protection-mode runtime status, especially when native ownership is active

Common fields:
- `modeState`
- `coverageLevel`
- `runtimeState`
- `bleOwner`
- `protectedDeviceId`
- `serviceBleConnected`
- `serviceBleReady`
- `restorationConfigured`
- `reconnectAttemptCount`
- `lastReconnectAttemptAt`
- `degradationReason`
- `lastCommandRoute`
- `lastCommandResult`
- `lastCommandError`

## `ProtectionDiagnostics`

Purpose:
- detailed diagnostics for wake events, reconnects, queueing, and native command routing

Common fields:
- `lastWakeReason`
- `lastFailureReason`
- `lastPlatformEvent`
- `lastRestorationEvent`
- `reconnectAttemptCount`
- `lastReconnectAttemptAt`
- `protectedDeviceId`
- `lastCommandRoute`
- `lastCommandResult`
- `lastCommandError`
- `pendingSosCount`
- `pendingTelemetryCount`

## `BackendRegisteredDevice`

Purpose:
- backend registry record for a device associated with the signed user

Common fields:
- `id`
- `hardwareId`
- `firmwareVersion`
- `hardwareModel`
- `pairedAt`
- `updatedAt`
