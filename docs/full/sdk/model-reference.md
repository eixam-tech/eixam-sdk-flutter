# Model Reference

This page summarizes the return types host apps most often inspect.

## `SdkOperationalDiagnostics`

Common fields:
- `connectionState`
- `session`
- `telemetryPublishTopic`
- `sosEventTopics`
- `sosRehydrationNote`
- `bridge.lastDecision`
- `bridge.pendingSos`
- `bridge.pendingTelemetry`

## `DeviceStatus`

Common fields:
- `deviceId`
- `lifecycleState`
- `paired`
- `activated`
- `connected`
- `isReadyForSafety`
- `approximateBatteryPercentage`
- `signalQuality`
- `firmwareVersion`
- `provisioningError`

## `DeviceSosStatus`

Common fields:
- `state`
- `lastEvent`
- `transitionSource`
- `updatedAt`
- `countdownRemainingSeconds`
- `lastPacketAt`
- `decoderNote`

## `EmergencyContact`

Common fields:
- `id`
- `name`
- `phone`
- `email`
- `priority`
- `updatedAt`

## `SosIncident`

Common fields:
- `id`
- `state`
- `createdAt`
- `triggerSource`
- `message`
- `positionSnapshot`

## `PermissionState`

Common fields:
- `location`
- `notifications`
- `bluetooth`
- `bluetoothEnabled`
- `hasLocationAccess`
- `hasNotificationAccess`
- `canUseBluetooth`

## `ProtectionStatus`

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

Common fields:
- `id`
- `hardwareId`
- `firmwareVersion`
- `hardwareModel`
- `pairedAt`
- `updatedAt`
