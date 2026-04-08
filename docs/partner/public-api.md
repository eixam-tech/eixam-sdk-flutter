# Public API

This page describes the recommended public surface exposed to partner host apps.

## Entry point

### `EixamConnectSdk.bootstrap(...)`

This is the recommended public entrypoint.

Use it to create an SDK instance, resolve the selected environment, validate the bootstrap configuration and optionally seed the initial signed session.

## Session lifecycle

- `setSession(...)`
- `clearSession()`
- `getCurrentSession()`
- `refreshCanonicalIdentity()`

## Diagnostics and protection

- `getOperationalDiagnostics()`
- `watchOperationalDiagnostics()`
- `evaluateProtectionReadiness()`
- `enterProtectionMode(...)`
- `exitProtectionMode()`
- `getProtectionStatus()`
- `watchProtectionStatus()`
- `getProtectionDiagnostics()`
- `watchProtectionDiagnostics()`
- `rehydrateProtectionState()`
- `flushProtectionQueues()`

## Device runtime and backend device registry

- `connectDevice(...)`
- `disconnectDevice()`
- `preferredDevice`
- `deviceStatusStream`
- `listRegisteredDevices()`
- `upsertRegisteredDevice(...)`
- `deleteRegisteredDevice(...)`

## SOS

- `triggerSos(...)`
- `cancelSos()`
- `getCurrentSosIncident()`
- `getSosState()`
- `currentSosStateStream`
- `lastSosEventStream`
- `watchEvents()`

## Contacts

- `listEmergencyContacts()`
- `watchEmergencyContacts()`
- `createEmergencyContact(...)`
- `updateEmergencyContact(...)`
- `deleteEmergencyContact(...)`

## Permissions and notifications

- `getPermissionState()`
- `requestLocationPermission()`
- `requestNotificationPermission()`
- `requestBluetoothPermission()`
- `initializeNotifications()`
- `showLocalNotification(...)`

## Tracking and telemetry

- `startTracking()`
- `stopTracking()`
- `publishTelemetry(...)`
- `getCurrentPosition()`
- `getTrackingState()`
- `watchPositions()`
- `watchTrackingState()`

## Death Man

- `scheduleDeathMan(...)`
- `getActiveDeathManPlan()`
- `confirmDeathManCheckIn(...)`
- `cancelDeathMan(...)`
- `watchDeathManPlans()`

## Realtime

- `getRealtimeConnectionState()`
- `getLastRealtimeEvent()`
- `watchRealtimeConnectionState()`
- `watchRealtimeEvents()`

## Intentionally omitted from the partner path

The current partner site does not present Guided Rescue Phase 1 as part of the public integration path.

## Legacy / compatibility surfaces

Some deprecated or compatibility methods still exist in the SDK contract for migration or internal validation purposes. They are documented in the full internal site.
