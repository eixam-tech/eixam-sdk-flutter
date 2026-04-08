# Quickstart

## 1. Add the dependency

```yaml
dependencies:
  eixam_connect_flutter:
    git:
      url: https://github.com/eixam-tech/eixam-sdk-flutter
      ref: v0.3.0
      path: packages/eixam_connect_flutter
```

## 2. Import the package

```dart
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
```

## 3. Bootstrap the SDK

### Standard environment

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

### Custom environment

```dart
final sdk = await EixamConnectSdk.bootstrap(
  const EixamBootstrapConfig(
    appId: 'partner-app',
    environment: EixamEnvironment.custom,
    customEndpoints: EixamCustomEndpoints(
      httpBaseUrl: 'https://partner-api.example.com',
      mqttUrl: 'wss://partner-mqtt.example.com/mqtt',
    ),
  ),
);
```

## 4. Request permissions explicitly from your host app

```dart
await sdk.requestLocationPermission();
await sdk.requestNotificationPermission();
await sdk.requestBluetoothPermission();
```

## 5. Use the SDK

Trigger SOS:

```dart
await sdk.triggerSos(
  const SosTriggerPayload(
    message: 'Need assistance',
    triggerSource: 'button_ui',
  ),
);
```

Connect a device:

```dart
await sdk.connectDevice(pairingCode: '123456');
```

Create an emergency contact:

```dart
await sdk.createEmergencyContact(
  name: 'Mountain Rescue Desk',
  phone: '+34600000000',
  email: 'rescue@example.com',
);
```

## Important notes

- `initialSession` is optional
- if you provide `initialSession`, its `appId` must match the bootstrap `appId`
- do not pass `customEndpoints` to non-custom environments
- bootstrap does not request permissions or trigger UX-sensitive actions for you
