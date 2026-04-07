# Public API

High-level reference of the current public `EixamConnectSdk` facade. See **API Examples** for code snippets.

## Initialization and session
- `initialize`
- `setSession`
- `clearSession`
- `getCurrentSession`
- `refreshCanonicalIdentity`

## Operational diagnostics and protection
- `getOperationalDiagnostics`
- `watchOperationalDiagnostics`
- `evaluateProtectionReadiness`
- `enterProtectionMode`
- `exitProtectionMode`
- `getProtectionStatus`
- `watchProtectionStatus`
- `getProtectionDiagnostics`
- `watchProtectionDiagnostics`
- `rehydrateProtectionState`
- `flushProtectionQueues`

## SOS
- `triggerSos`
- `getCurrentSosIncident`
- `currentSosStateStream`
- `lastSosEventStream`
- `cancelSos`
- `getSosState`
- `watchSosState` _(legacy)_

## Contacts
- `createEmergencyContact`
- `deleteEmergencyContact`
- `listEmergencyContacts`
- `watchEmergencyContacts`
- `addEmergencyContact` _(legacy)_
- `updateEmergencyContact`
- `removeEmergencyContact` _(legacy)_

## Permissions and notifications
- `getPermissionState`
- `requestLocationPermission`
- `requestNotificationPermission`
- `requestBluetoothPermission`
- `initializeNotifications`
- `showLocalNotification`

## Local device runtime
- `connectDevice`
- `disconnectDevice`
- `preferredDevice`
- `deviceStatusStream`
- `pairDevice` _(legacy)_
- `activateDevice`
- `getDeviceStatus`
- `refreshDeviceStatus`
- `unpairDevice` _(legacy)_
- `watchDeviceStatus` _(legacy)_
- `getDeviceSosStatus`
- `watchDeviceSosStatus`
- `triggerDeviceSos`
- `confirmDeviceSos`
- `cancelDeviceSos`
- `acknowledgeDeviceSos`
- `sendInetOkToDevice`
- `sendInetLostToDevice`
- `sendPositionConfirmedToDevice`
- `sendSosAckRelayToDevice`
- `sendShutdownToDevice`
- `consumePendingBleNotificationNavigationRequest`
- `watchBleNotificationNavigationRequests`

## Backend device registry
- `listRegisteredDevices`
- `upsertRegisteredDevice`
- `deleteRegisteredDevice`

## Tracking and telemetry
- `startTracking`
- `stopTracking`
- `publishTelemetry`
- `getCurrentPosition`
- `getTrackingState`
- `watchPositions`
- `watchTrackingState`

## Death Man
- `scheduleDeathMan`
- `getActiveDeathManPlan`
- `confirmDeathManCheckIn`
- `cancelDeathMan`
- `watchDeathManPlans`

## Events and realtime
- `watchEvents`
- `getRealtimeConnectionState`
- `getLastRealtimeEvent`
- `watchRealtimeConnectionState`
- `watchRealtimeEvents`
