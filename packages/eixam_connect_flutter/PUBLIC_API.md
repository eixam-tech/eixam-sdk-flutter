# Public API

This document defines the official partner-facing API boundary for `eixam_connect_flutter`.

The only supported public import for external partners is:

```dart
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
```

Only symbols exported from `package:eixam_connect_flutter/eixam_connect_flutter.dart` are considered supported public API.

## Supported Public API

### Initialization / Session

- `ApiSdkFactory`
- `EixamConnectSdk.initialize`
- `EixamConnectSdk.setSession`
- `EixamConnectSdk.clearSession`
- `EixamConnectSdk.getCurrentSession`
- `EixamConnectSdk.refreshCanonicalIdentity`
- Public types such as `EixamSdkConfig` and `EixamSession`

### Device Lifecycle

- `EixamConnectSdk.connectDevice`
- `EixamConnectSdk.disconnectDevice`
- `EixamConnectSdk.preferredDevice`
- `EixamConnectSdk.getDeviceStatus`
- `EixamConnectSdk.refreshDeviceStatus`
- `EixamConnectSdk.deviceStatusStream`
- Device command and device SOS methods exposed on `EixamConnectSdk`
- Public types such as `DeviceStatus`, `DeviceSosStatus`, `PreferredDevice`, and `BackendRegisteredDevice`

### Permissions

- `EixamConnectSdk.getPermissionState`
- `EixamConnectSdk.requestLocationPermission`
- `EixamConnectSdk.requestNotificationPermission`
- `EixamConnectSdk.requestBluetoothPermission`
- `EixamConnectSdk.initializeNotifications`
- `EixamConnectSdk.showLocalNotification`
- Public types such as `PermissionState`

### Emergency Contacts

- `EixamConnectSdk.listEmergencyContacts`
- `EixamConnectSdk.watchEmergencyContacts`
- `EixamConnectSdk.createEmergencyContact`
- `EixamConnectSdk.updateEmergencyContact`
- `EixamConnectSdk.deleteEmergencyContact`
- Public types such as `EmergencyContact`

### Telemetry / Tracking

- `EixamConnectSdk.publishTelemetry`
- `EixamConnectSdk.startTracking`
- `EixamConnectSdk.stopTracking`
- `EixamConnectSdk.getCurrentPosition`
- `EixamConnectSdk.getTrackingState`
- `EixamConnectSdk.watchPositions`
- `EixamConnectSdk.watchTrackingState`
- Public types such as `SdkTelemetryPayload`, `TrackingPosition`, and `TrackingState`

### SOS

- `EixamConnectSdk.triggerSos`
- `EixamConnectSdk.cancelSos`
- `EixamConnectSdk.getCurrentSosIncident`
- `EixamConnectSdk.getSosState`
- `EixamConnectSdk.currentSosStateStream`
- `EixamConnectSdk.lastSosEventStream`
- `EixamConnectSdk.watchEvents`
- Public types such as `SosTriggerPayload`, `SosIncident`, `SosState`, and `EixamSdkEvent`

### Diagnostics

- `EixamConnectSdk.getOperationalDiagnostics`
- `EixamConnectSdk.watchOperationalDiagnostics`
- realtime status and event methods on `EixamConnectSdk`
- Protection Mode readiness, status, diagnostics, and rehydration methods on `EixamConnectSdk`
- Public types such as `SdkOperationalDiagnostics`, `RealtimeEvent`, `RealtimeConnectionState`, `ProtectionStatus`, and `ProtectionDiagnostics`

## Not Public API

The following are not supported partner integration points:

- internal repositories
- platform adapters
- BLE / protocol packet classes
- validation / debug helpers
- internal controllers
- runtime / storage internals
- anything under `package:eixam_connect_flutter/src/...`

## Compatibility Promise

EIXAM aims to keep the public API exported from `eixam_connect_flutter.dart` stable for partner integrations.

If a change affects that public surface, it should be treated as a versioned SDK change and communicated accordingly. Anything outside the public export surface may change without notice.
