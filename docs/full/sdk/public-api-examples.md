# Public API — Method Examples

All examples below assume:

```dart
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';

late final EixamConnectSdk sdk;
```

> The partner-facing recommendation is to create the SDK with `EixamConnectSdk.bootstrap(...)` and then treat the remaining methods as capability-specific calls made from your host app lifecycle and UX.

## Bootstrap

### `bootstrap`

Recommended public entrypoint.

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
```

## Session lifecycle

### `setSession`

```dart
await sdk.setSession(
  const EixamSession.signed(
    appId: 'partner-app',
    externalUserId: 'partner-user-123',
    userHash: 'signed-session-hash',
  ),
);
```

### `clearSession`

```dart
await sdk.clearSession();
```

### `getCurrentSession`

```dart
final session = await sdk.getCurrentSession();
if (session != null) {
  debugPrint(session.externalUserId);
}
```

### `refreshCanonicalIdentity`

```dart
final canonical = await sdk.refreshCanonicalIdentity();
debugPrint(canonical.canonicalExternalUserId);
```

## Diagnostics and Protection Mode

### `getOperationalDiagnostics`

```dart
final diagnostics = await sdk.getOperationalDiagnostics();
debugPrint(diagnostics.toString());
```

### `watchOperationalDiagnostics`

```dart
final sub = sdk.watchOperationalDiagnostics().listen((diagnostics) {
  debugPrint(diagnostics.toString());
});
```

### `evaluateProtectionReadiness`

```dart
final readiness = await sdk.evaluateProtectionReadiness();
debugPrint(readiness.toString());
```

### `enterProtectionMode`

```dart
await sdk.enterProtectionMode(
  options: const ProtectionModeOptions(),
);
```

### `exitProtectionMode`

```dart
await sdk.exitProtectionMode();
```

### `getProtectionStatus`

```dart
final status = await sdk.getProtectionStatus();
debugPrint(status.modeState.name);
```

### `watchProtectionStatus`

```dart
final sub = sdk.watchProtectionStatus().listen((status) {
  debugPrint(status.modeState.name);
});
```

### `getProtectionDiagnostics`

```dart
final diagnostics = await sdk.getProtectionDiagnostics();
debugPrint(diagnostics.toString());
```

### `watchProtectionDiagnostics`

```dart
final sub = sdk.watchProtectionDiagnostics().listen((diagnostics) {
  debugPrint(diagnostics.toString());
});
```

### `rehydrateProtectionState`

```dart
final status = await sdk.rehydrateProtectionState();
debugPrint(status.runtimeState.name);
```

### `flushProtectionQueues`

```dart
final result = await sdk.flushProtectionQueues();
debugPrint(result.toString());
```

## Device runtime and backend registry

### `connectDevice`

```dart
final device = await sdk.connectDevice(pairingCode: '123456');
debugPrint(device.deviceId);
```

### `disconnectDevice`

```dart
await sdk.disconnectDevice();
```

### `preferredDevice`

```dart
final preferred = await sdk.preferredDevice;
if (preferred != null) {
  debugPrint(preferred.deviceId);
}
```

### `deviceStatusStream`

```dart
final sub = sdk.deviceStatusStream.listen((status) {
  debugPrint(status.lifecycleState.name);
});
```

### `listRegisteredDevices`

```dart
final devices = await sdk.listRegisteredDevices();
debugPrint(devices.length.toString());
```

### `upsertRegisteredDevice`

```dart
final device = await sdk.upsertRegisteredDevice(
  hardwareId: 'hw-001',
  firmwareVersion: '1.0.0',
  hardwareModel: 'EIXAM_NODE',
  pairedAt: DateTime.now().toUtc(),
);
```

### `deleteRegisteredDevice`

```dart
await sdk.deleteRegisteredDevice('device-id');
```

## SOS

### `triggerSos`

```dart
await sdk.triggerSos(
  const SosTriggerPayload(
    message: 'Need assistance',
    triggerSource: 'button_ui',
  ),
);
```

### `getCurrentSosIncident`

```dart
final incident = await sdk.getCurrentSosIncident();
if (incident != null) {
  debugPrint(incident.id);
}
```

### `currentSosStateStream`

```dart
final sub = sdk.currentSosStateStream.listen((state) {
  debugPrint(state.name);
});
```

### `lastSosEventStream`

```dart
final sub = sdk.lastSosEventStream.listen((event) {
  debugPrint(event.runtimeType.toString());
});
```

### `cancelSos`

```dart
await sdk.cancelSos();
```

### `getSosState`

```dart
final state = await sdk.getSosState();
debugPrint(state.name);
```

### `watchEvents`

```dart
final sub = sdk.watchEvents().listen((event) {
  debugPrint(event.runtimeType.toString());
});
```

## Contacts

### `createEmergencyContact`

```dart
final contact = await sdk.createEmergencyContact(
  name: 'Mountain Rescue Desk',
  phone: '+34600000000',
  email: 'rescue@example.com',
  priority: 1,
);
```

### `listEmergencyContacts`

```dart
final contacts = await sdk.listEmergencyContacts();
debugPrint(contacts.length.toString());
```

### `watchEmergencyContacts`

```dart
final sub = sdk.watchEmergencyContacts().listen((contacts) {
  debugPrint(contacts.length.toString());
});
```

### `updateEmergencyContact`

```dart
final contact = await sdk.createEmergencyContact(
  name: 'Mountain Rescue Desk',
  phone: '+34600000000',
  email: 'rescue@example.com',
);

await sdk.updateEmergencyContact(
  contact.copyWith(name: 'Mountain Rescue 24/7'),
);
```

### `deleteEmergencyContact`

```dart
await sdk.deleteEmergencyContact('contact-id');
```

## Permissions and notifications

### `getPermissionState`

```dart
final state = await sdk.getPermissionState();
debugPrint(state.toString());
```

### `requestLocationPermission`

```dart
await sdk.requestLocationPermission();
```

### `requestNotificationPermission`

```dart
await sdk.requestNotificationPermission();
```

### `requestBluetoothPermission`

```dart
await sdk.requestBluetoothPermission();
```

### `initializeNotifications`

```dart
await sdk.initializeNotifications();
```

### `showLocalNotification`

```dart
await sdk.showLocalNotification(
  title: 'EIXAM',
  body: 'Device connected',
);
```

## Tracking and telemetry

### `startTracking`

```dart
await sdk.startTracking();
```

### `stopTracking`

```dart
await sdk.stopTracking();
```

### `publishTelemetry`

```dart
await sdk.publishTelemetry(
  SdkTelemetryPayload(
    timestamp: DateTime.now().toUtc(),
    latitude: 42.5063,
    longitude: 1.5218,
    altitude: 1820,
    mobileBattery: 0.84,
    mobileCoverage: 4,
  ),
);
```

### `getCurrentPosition`

```dart
final position = await sdk.getCurrentPosition();
if (position != null) {
  debugPrint('${position.latitude}, ${position.longitude}');
}
```

### `getTrackingState`

```dart
final state = await sdk.getTrackingState();
debugPrint(state.name);
```

### `watchPositions`

```dart
final sub = sdk.watchPositions().listen((position) {
  debugPrint('${position.latitude}, ${position.longitude}');
});
```

### `watchTrackingState`

```dart
final sub = sdk.watchTrackingState().listen((state) {
  debugPrint(state.name);
});
```

## Death Man

### `scheduleDeathMan`

```dart
final plan = await sdk.scheduleDeathMan(
  expectedReturnAt: DateTime.now().toUtc().add(const Duration(hours: 4)),
  gracePeriod: const Duration(minutes: 30),
  checkInWindow: const Duration(minutes: 10),
  autoTriggerSos: true,
);
```

### `getActiveDeathManPlan`

```dart
final plan = await sdk.getActiveDeathManPlan();
if (plan != null) {
  debugPrint(plan.id);
}
```

### `confirmDeathManCheckIn`

```dart
await sdk.confirmDeathManCheckIn('plan-id');
```

### `cancelDeathMan`

```dart
await sdk.cancelDeathMan('plan-id');
```

### `watchDeathManPlans`

```dart
final sub = sdk.watchDeathManPlans().listen((plan) {
  debugPrint(plan.status.name);
});
```

## Realtime

### `getRealtimeConnectionState`

```dart
final state = await sdk.getRealtimeConnectionState();
debugPrint(state.name);
```

### `getLastRealtimeEvent`

```dart
final event = await sdk.getLastRealtimeEvent();
if (event != null) {
  debugPrint(event.type);
}
```

### `watchRealtimeConnectionState`

```dart
final sub = sdk.watchRealtimeConnectionState().listen((state) {
  debugPrint(state.name);
});
```

### `watchRealtimeEvents`

```dart
final sub = sdk.watchRealtimeEvents().listen((event) {
  debugPrint(event.type);
});
```

## Low-level device controls

### `activateDevice`

```dart
final status = await sdk.activateDevice(activationCode: 'ACT-001');
debugPrint(status.activated.toString());
```

### `getDeviceStatus`

```dart
final status = await sdk.getDeviceStatus();
debugPrint(status.lifecycleState.name);
```

### `refreshDeviceStatus`

```dart
final status = await sdk.refreshDeviceStatus();
debugPrint(status.connected.toString());
```

### `getDeviceSosStatus`

```dart
final status = await sdk.getDeviceSosStatus();
debugPrint(status.state.name);
```

### `watchDeviceSosStatus`

```dart
final sub = sdk.watchDeviceSosStatus().listen((status) {
  debugPrint(status.state.name);
});
```

### `triggerDeviceSos`

```dart
await sdk.triggerDeviceSos();
```

### `confirmDeviceSos`

```dart
await sdk.confirmDeviceSos();
```

### `cancelDeviceSos`

```dart
await sdk.cancelDeviceSos();
```

### `acknowledgeDeviceSos`

```dart
await sdk.acknowledgeDeviceSos();
```

### `sendInetOkToDevice`

```dart
await sdk.sendInetOkToDevice();
```

### `sendInetLostToDevice`

```dart
await sdk.sendInetLostToDevice();
```

### `sendPositionConfirmedToDevice`

```dart
await sdk.sendPositionConfirmedToDevice();
```

### `sendSosAckRelayToDevice`

```dart
await sdk.sendSosAckRelayToDevice(nodeId: 42);
```

### `sendShutdownToDevice`

```dart
await sdk.sendShutdownToDevice();
```

### `consumePendingBleNotificationNavigationRequest`

```dart
final request = await sdk.consumePendingBleNotificationNavigationRequest();
if (request != null) {
  debugPrint(request.toString());
}
```

### `watchBleNotificationNavigationRequests`

```dart
final sub = sdk.watchBleNotificationNavigationRequests().listen((request) {
  debugPrint(request.toString());
});
```

## Deprecated / compatibility surfaces

### `pairDevice`

Compatibility example kept for migrations. New integrations should prefer the replacement method called out in the code comment.

```dart
// Deprecated: use connectDevice(...) instead.
await sdk.pairDevice(pairingCode: '123456');
```

### `unpairDevice`

Compatibility example kept for migrations. New integrations should prefer the replacement method called out in the code comment.

```dart
// Deprecated: use disconnectDevice() instead.
await sdk.unpairDevice();
```

### `watchDeviceStatus`

Compatibility example kept for migrations. New integrations should prefer the replacement method called out in the code comment.

```dart
// Deprecated: use deviceStatusStream instead.
final sub = sdk.watchDeviceStatus().listen((status) {
  debugPrint(status.lifecycleState.name);
});
```

### `watchSosState`

Compatibility example kept for migrations. New integrations should prefer the replacement method called out in the code comment.

```dart
// Deprecated: use currentSosStateStream instead.
final sub = sdk.watchSosState().listen((state) {
  debugPrint(state.name);
});
```

### `addEmergencyContact`

Compatibility example kept for migrations. New integrations should prefer the replacement method called out in the code comment.

```dart
// Deprecated: use createEmergencyContact(...) instead.
await sdk.addEmergencyContact(
  name: 'Mountain Rescue Desk',
  phone: '+34600000000',
  email: 'rescue@example.com',
);
```

### `removeEmergencyContact`

Compatibility example kept for migrations. New integrations should prefer the replacement method called out in the code comment.

```dart
// Deprecated: use deleteEmergencyContact(...) instead.
await sdk.removeEmergencyContact('contact-id');
```

## Experimental / internal-only surfaces

### `getGuidedRescueState`

This surface is intentionally **not** part of the current partner path. It is documented here only for internal completeness.

```dart
final state = await sdk.getGuidedRescueState();
debugPrint(state.toString());
```

### `watchGuidedRescueState`

This surface is intentionally **not** part of the current partner path. It is documented here only for internal completeness.

```dart
final sub = sdk.watchGuidedRescueState().listen((state) {
  debugPrint(state.toString());
});
```

### `setGuidedRescueSession`

This surface is intentionally **not** part of the current partner path. It is documented here only for internal completeness.

```dart
await sdk.setGuidedRescueSession(
  targetNodeId: 1001,
  rescueNodeId: 2002,
);
```

### `clearGuidedRescueSession`

This surface is intentionally **not** part of the current partner path. It is documented here only for internal completeness.

```dart
await sdk.clearGuidedRescueSession();
```

### `requestGuidedRescuePosition`

This surface is intentionally **not** part of the current partner path. It is documented here only for internal completeness.

```dart
await sdk.requestGuidedRescuePosition();
```

### `acknowledgeGuidedRescueSos`

This surface is intentionally **not** part of the current partner path. It is documented here only for internal completeness.

```dart
await sdk.acknowledgeGuidedRescueSos();
```

### `enableGuidedRescueBuzzer`

This surface is intentionally **not** part of the current partner path. It is documented here only for internal completeness.

```dart
await sdk.enableGuidedRescueBuzzer();
```

### `disableGuidedRescueBuzzer`

This surface is intentionally **not** part of the current partner path. It is documented here only for internal completeness.

```dart
await sdk.disableGuidedRescueBuzzer();
```

### `requestGuidedRescueStatus`

This surface is intentionally **not** part of the current partner path. It is documented here only for internal completeness.

```dart
await sdk.requestGuidedRescueStatus();
```
