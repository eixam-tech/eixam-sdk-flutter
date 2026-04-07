# Quickstart

## 1. Add dependencies

```yaml
dependencies:
  eixam_connect_core:
    path: ../../packages/eixam_connect_core
  eixam_connect_flutter:
    path: ../../packages/eixam_connect_flutter
```

## 2. Create the SDK

```dart
final sdk = await ApiSdkFactory.createHttpApi(
  apiBaseUrl: 'https://api.example.com',
  websocketUrl: 'wss://mqtt.example.com/mqtt',
);
```

## 3. Provide the signed session

```dart
await sdk.setSession(
  const EixamSession.signed(
    appId: 'partner-app',
    externalUserId: 'partner-user-123',
    userHash: 'signed-token-or-hash',
  ),
);
```

## 4. Subscribe to streams

```dart
sdk.currentSosStateStream.listen((state) {
  // render SOS state
});

sdk.deviceStatusStream.listen((status) {
  // render runtime device state
});
```
