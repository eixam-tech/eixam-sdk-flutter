# Quickstart

## 1. Add the dependency

For the planned `0.1.0` release, use the agreed EIXAM release tag when it is provided during release handoff.

```yaml
dependencies:
  eixam_connect_flutter:
    git:
      url: https://github.com/eixam-tech/eixam-sdk-flutter
      ref: <agreed-0.1.0-release-tag>
      path: packages/eixam_connect_flutter
```

## 2. Import the package

```dart
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
```

## 3. Bootstrap the SDK

## Signed Session And Backend Responsibilities

- your partner backend stores the app secret
- the app secret never belongs in the client
- your backend generates or obtains `userHash` for `appId` + `externalUserId`
- `externalUserId` must be unique per app
- the mobile app receives a signed session and passes it to the SDK
- the same signed identity is reused by the SDK for both HTTP and MQTT/runtime transport
- `/v1/auth/sign` is acceptable for internal EIXAM staging validation only; partner production flows must implement the server-side signing step in the partner backend

HTTP auth remains:

- `X-App-ID`
- `X-User-ID`
- `Authorization: Bearer <userHash>`

MQTT auth now uses:

- `username = sdk:<appId>:<externalUserId>`
- `password = <userHash>`
- no `Bearer` prefix in MQTT

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
      apiBaseUrl: 'https://partner-api.example.com',
      mqttUrl: 'ssl://partner-mqtt.example.com:8883',
    ),
  ),
);
```

The `mqttUrl`/`websocketUrl` field name stays stable for now even when the actual broker URI uses `ssl://`, `tls://`, `tcp://`, `ws://`, or `wss://` depending on environment and transport support.

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
