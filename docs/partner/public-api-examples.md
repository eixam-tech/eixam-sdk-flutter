# Public API - Practical Examples

All examples below assume:

```dart
import 'package:flutter/foundation.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';

late final EixamConnectSdk sdk;
```

These examples focus on the fields partner apps usually inspect in practice.

## Bootstrap

### `bootstrap`

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
debugPrint('user=${session?.externalUserId}');
```

## Diagnostics

### `getOperationalDiagnostics`

Returns [`SdkOperationalDiagnostics`](model-reference.md#sdkoperationaldiagnostics).

```dart
final diagnostics = await sdk.getOperationalDiagnostics();
debugPrint('mqtt=${diagnostics.connectionState.name}');
debugPrint('telTopic=${diagnostics.telemetryPublishTopic}');
debugPrint('lastDecision=${diagnostics.bridge.lastDecision}');
debugPrint('hasPendingSos=${diagnostics.bridge.pendingSos != null}');
```

### `watchOperationalDiagnostics`

Returns `Stream<SdkOperationalDiagnostics>`.

```dart
final sub = sdk.watchOperationalDiagnostics().listen((diagnostics) {
  debugPrint('mqtt=${diagnostics.connectionState.name}');
  debugPrint('bleTel=${diagnostics.bridge.lastBleTelemetryEventSummary}');
  debugPrint('bleSos=${diagnostics.bridge.lastBleSosEventSummary}');
});
```

## Device Lifecycle

### `connectDevice`

Returns [`DeviceStatus`](model-reference.md#devicestatus).

```dart
final status = await sdk.connectDevice(pairingCode: '123456');
debugPrint('device=${status.deviceId}');
debugPrint('lifecycle=${status.lifecycleState.name}');
debugPrint('ready=${status.isReadyForSafety}');
```

### `getDeviceStatus`

Returns [`DeviceStatus`](model-reference.md#devicestatus).

```dart
final status = await sdk.getDeviceStatus();
debugPrint('connected=${status.connected}');
debugPrint('firmware=${status.firmwareVersion}');
debugPrint('battery=${status.approximateBatteryPercentage}');
```

### `deviceStatusStream`

Returns `Stream<DeviceStatus>`.

```dart
final sub = sdk.deviceStatusStream.listen((status) {
  debugPrint('lifecycle=${status.lifecycleState.name}');
  debugPrint('connected=${status.connected}');
  debugPrint('signal=${status.signalQuality}');
});
```

### `getDeviceSosStatus`

Returns [`DeviceSosStatus`](model-reference.md#devicesosstatus).

```dart
final status = await sdk.getDeviceSosStatus();
debugPrint('state=${status.state.name}');
debugPrint('event=${status.lastEvent}');
debugPrint('countdown=${status.countdownRemainingSeconds}');
```

## SOS

### `triggerSos`

Returns [`SosIncident`](model-reference.md#sosincident).

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

### `getCurrentSosIncident`

Returns `Future<SosIncident?>`.

```dart
final incident = await sdk.getCurrentSosIncident();
if (incident != null) {
  debugPrint('incident=${incident.id}');
  debugPrint('state=${incident.state.name}');
  debugPrint('hasPosition=${incident.positionSnapshot != null}');
}
```

### `getSosState`

Returns `Future<SosState>`.

```dart
final state = await sdk.getSosState();
debugPrint('sosState=${state.name}');
```

## Contacts

### `listEmergencyContacts`

Returns `Future<List<EmergencyContact>>`.

```dart
final contacts = await sdk.listEmergencyContacts();
for (final contact in contacts) {
  debugPrint('${contact.priority}: ${contact.name} ${contact.phone}');
}
```

### `createEmergencyContact`

Returns [`EmergencyContact`](model-reference.md#emergencycontact).

```dart
final contact = await sdk.createEmergencyContact(
  name: 'Mountain Rescue Desk',
  phone: '+34600000000',
  email: 'rescue@example.com',
  priority: 1,
);

debugPrint('contact=${contact.id}');
debugPrint('phone=${contact.phone}');
debugPrint('priority=${contact.priority}');
```

### `updateEmergencyContact`

Returns [`EmergencyContact`](model-reference.md#emergencycontact).

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

### `getPermissionState`

Returns [`PermissionState`](model-reference.md#permissionstate).

```dart
final state = await sdk.getPermissionState();
debugPrint('location=${state.location.name}');
debugPrint('notifications=${state.notifications.name}');
debugPrint('bluetooth=${state.bluetooth.name}');
debugPrint('bluetoothReady=${state.canUseBluetooth}');
```

## Protection Mode

### `getProtectionStatus`

Returns [`ProtectionStatus`](model-reference.md#protectionstatus).

```dart
final status = await sdk.getProtectionStatus();
debugPrint('mode=${status.modeState.name}');
debugPrint('runtime=${status.runtimeState.name}');
debugPrint('owner=${status.bleOwner.name}');
debugPrint('protectedDevice=${status.protectedDeviceId}');
```

### `getProtectionDiagnostics`

Returns [`ProtectionDiagnostics`](model-reference.md#protectiondiagnostics).

```dart
final diagnostics = await sdk.getProtectionDiagnostics();
debugPrint('wake=${diagnostics.lastWakeReason}');
debugPrint('reconnects=${diagnostics.reconnectAttemptCount}');
debugPrint('route=${diagnostics.lastCommandRoute}');
debugPrint('result=${diagnostics.lastCommandResult}');
```

## Backend Device Registry

### `listRegisteredDevices`

Returns `Future<List<BackendRegisteredDevice>>`.

```dart
final devices = await sdk.listRegisteredDevices();
for (final device in devices) {
  debugPrint('${device.hardwareId} ${device.firmwareVersion}');
}
```
