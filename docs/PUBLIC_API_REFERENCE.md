# Public API reference

This is a curated integration index for the public symbols exported by
`package:eixam_connect_flutter/eixam_connect_flutter.dart`. It is not a
replacement for generated Dart API documentation. Symbols absent from that
entry point are implementation details even when they exist under `lib/src`.

## Bootstrap and session

| Symbol | Purpose |
| --- | --- |
| `EixamConnectSdk.bootstrap` | Creates and initializes the Android/iOS SDK runtime |
| `EixamBootstrapConfig` | App ID, environment, localized notification text, optional session, policy, feature flags, and logging controls |
| `EixamEnvironment` | `production`, `sandbox`, `staging`, or `custom` |
| `EixamCustomEndpoints` | API and realtime endpoints for the custom environment |
| `EixamSession.signed` | Host-supplied signed SDK identity |
| `setSession`, `startDeferredRuntime`, `clearSession` | Attach, start deferred work, and detach runtime identity |
| `getCurrentSession`, `refreshCanonicalIdentity` | Read or refresh authenticated SDK identity |

## Readiness, permissions, and diagnostics

| API | Result/stream |
| --- | --- |
| `getPermissionState` | `PermissionState` |
| `preparePermissionPreflight`, `acceptPermissionDisclosure`, `declinePermissionDisclosure` | `EixamPermissionPreflightResult` |
| `requestBluetoothPermission`, `requestLocationPermission`, `requestNotificationPermission` | `PermissionState` |
| `evaluateProtectionReadiness` | `ProtectionReadinessReport` |
| `getOperationalDiagnostics`, `watchOperationalDiagnostics` | `SdkOperationalDiagnostics` |
| `getBleDiagnostics`, `watchBleDiagnostics` | `EixamBleDiagnostics` |
| `getRealtimeConnectionState`, `watchRealtimeConnectionState` | `RealtimeConnectionState` |

Diagnostics describe support state. They are not substitutes for lifecycle,
capability, permission, or connection streams.

## Devices and reconnect

| API | Contract |
| --- | --- |
| `scanBleDevices` | Returns `List<EixamBleScanResult>` |
| `connectDevice`, `disconnectDevice` | Connects by pairing code and disconnects |
| `deviceStatusStream`, `getDeviceStatus`, `refreshDeviceStatus` | Typed device state |
| `getDeviceCommandChannelStatus`, `watchDeviceCommandChannelStatus` | `BleCommandChannelStatus` readiness |
| `preferredDevice` | Last preferred `PreferredDevice`, when known |
| `bootstrapPreferredDeviceReconnect`, `reconnectPreferredDevice` | `PreferredDeviceReconnectResult` |
| `startPreferredDeviceReconnectMonitor`, `stopPreferredDeviceReconnectMonitor` | SDK reconnect monitor lifecycle |
| `listRegisteredDevices`, `upsertRegisteredDevice`, `deleteRegisteredDevice` | Backend device registration |
| `getDeviceSosStatus`, `watchDeviceSosStatus` | Connected-device SOS state |

`pairDevice`, `unpairDevice`, and `watchDeviceStatus` remain exported but are
deprecated in favor of the current members above.

## SOS lifecycle and capability

| API | Contract |
| --- | --- |
| `getSosLifecycle`, `sosLifecycleStream` | Authoritative `SosLifecycleSnapshot` |
| `getSosCapability`, `watchSosCapability`, `retrySosCapability` | `SosCapabilitySnapshot` |
| `triggerSosAuthoritatively` | `SosActivationResult` |
| `cancelSosAuthoritatively` | `SosCancellationResult` |
| `startPreSos`, `confirmPreSos`, `cancelPreSos` | SDK-owned countdown and dispatch |
| `getPreSosStatus`, `watchPreSosStatus` | `PublicPreSosStatus?` |
| `getCurrentSosIncident` | Current `SosIncident?` |
| `getCurrentSosTerminalReason` | `SosTerminalReason?` |
| `listSosHistory` | Paginated `SosHistoryPage` |

Authoritative lifecycle stages are `idle`, `arming`, `activating`, `active`,
`cancelling`, `cancelled`, `resolved`, `activationFailed`,
`cancellationFailed`, and `recoveryRequired`.

Lifecycle origins are `localApp`, `connectedLocalDevice`,
`registeredLocalDevice`, `remoteRelay`, `externalBackend`, and `unknown`.
Hosts decide active-versus-history presentation from typed actionability and
display fields, not origin strings alone.

Legacy `triggerSos`, `cancelSos`, `resolveSos`, `getSosState`, and
`currentSosStateStream` remain available. New integrations should use the
authoritative methods and stream for control flow.

## Incident progress

`getCurrentSosIncidentProgress` and
`currentSosIncidentProgressStream` are additive extension members on
`EixamConnectSdk`. They return `SosIncidentProgress?`.

Important models:

- `SosIncidentProgress`: revision, terminal flag, provisional/canonical
  presence, origin/actionability, and ordered progress steps;
- `SosProgressStep`: typed step, state, counts, update time, and detail code;
- `SosActuatorSnapshot`: versioned actuator items;
- `SosActuatorItem`, `SosActuatorContact`, `SosActuatorDelivery`: typed
  emergency-contact and channel evidence.

`SosProgressState` includes `pending`, `inProgress`, `succeeded`,
`partiallySucceeded`, `failed`, `unavailable`, `notApplicable`, and `unknown`.
Hosts must tolerate absent steps and unknown future backend values.

## Location and tracking

| API | Contract |
| --- | --- |
| `getResolvedLocationForEmergencyContext` | Nullable `SdkResolvedLocation` chosen by SDK authority rules |
| `watchResolvedLocation` | Resolved location updates |
| `getResolvedTelemetryPreview` | Nullable `SdkTelemetryPayload` preview |
| `getCurrentPosition`, `watchPositions` | Latest/streamed `TrackingPosition` |
| `startTracking`, `stopTracking` | Foreground tracking lifecycle |
| `enableBackgroundTelemetry`, `disableBackgroundTelemetry` | Compatibility sharing controls |

The optional `BackgroundLocationControl` capability exposes
`getLocationPermissionSnapshot`, permission requests,
`setBackgroundLocationContext`, `getBackgroundLocationStatus`, and
`watchBackgroundLocationStatus`. Check that the runtime implements the
capability before using it.

## Other public groups

The same entry point exports:

- profile and account APIs (`fetchSdkUserProfile`, `updateSdkUserProfile`,
  `deleteUserData`, `clearLocalUserData`);
- emergency contacts;
- Death Man Protocol plans;
- protection mode;
- notifications and navigation intents;
- firmware update and per-country radio configuration;
- telemetry publication;
- realtime events and SDK-wide events;
- public errors headed by `EixamSdkException` and typed feature exceptions.

Consult the interface source for the full parameter list. Do not import
unexported `src/` files to reach private controllers, stores, transport
classes, or platform bridges.

## Error handling

Public operations return typed results where the caller must distinguish
success, pending, blocked, degraded, terminal, and retryable outcomes. Catch
public SDK exception types for transport/configuration failures. Do not parse
exception messages, log markers, endpoint strings, or private diagnostic
values to drive application behavior.

See [SDK integration guide](SDK_INTEGRATION_GUIDE.md) for setup and
troubleshooting and
[Authoritative SOS lifecycle](SOS_LIFECYCLE_ARCHITECTURE_2026.md) for source,
identity, progress, cancellation, and stale-state rules.
