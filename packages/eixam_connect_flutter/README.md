# EIXAM Connect Flutter SDK

`eixam_connect_flutter` is the Flutter SDK for partners integrating EIXAM-powered SOS, connected device flows, telemetry, and operational diagnostics into their own app.

The SDK is designed so the host app stays focused on UI, navigation, and product-specific workflows, while EIXAM behavior is accessed through the public SDK facade.

## Installation

Add the package to your Flutter app using the version or delivery channel provided by EIXAM.

```yaml
dependencies:
  eixam_connect_flutter: <version-provided-by-eixam>
```

Import only the public entrypoint:

```dart
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
```

## Minimal Usage

Create the SDK:

```dart
final sdk = await ApiSdkFactory.createHttpApi(
  apiBaseUrl: '<eixam-api-base-url>',
  websocketUrl: '<eixam-realtime-websocket-url>',
);
```

Provide the signed session from your backend or auth flow:

```dart
await sdk.setSession(
  EixamSession.signed(
    appId: '<your-app-id>',
    externalUserId: '<partner-user-id>',
    userHash: '<signed-session-value>',
  ),
);
```

Render state from the public SDK streams:

```dart
sdk.currentSosStateStream.listen((state) {
  // Update your SOS UI.
});

sdk.deviceStatusStream.listen((status) {
  // Update your device UI.
});
```

Trigger user actions through the public facade:

```dart
await sdk.requestBluetoothPermission();
await sdk.connectDevice(pairingCode: '<pairing-code>');
await sdk.triggerSos(
  const SosTriggerPayload(
    message: 'Need help',
    triggerSource: 'partner_app',
  ),
);
```

## Documentation

- Partner docs: `docs/partner/`
- Public API boundary: [PUBLIC_API.md](./PUBLIC_API.md)
- Example app: `example/`
- Migration notes: [MIGRATION.md](./MIGRATION.md)

Replace these placeholders with the final external documentation URLs when the SDK release portal is live.

## Support Boundary

Only symbols exported from `package:eixam_connect_flutter/eixam_connect_flutter.dart` are supported public API for partners.

Internal repositories, platform adapters, BLE/protocol packet classes, validation helpers, internal controllers, and runtime/storage internals are not supported integration points.
