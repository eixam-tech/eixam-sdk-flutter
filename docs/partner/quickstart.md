# Quickstart

This page is for a partner team integrating EIXAM into its own app for the first time.

## Before you start

Before implementation begins, EIXAM provides the onboarding inputs your team needs for integration:

- `appId`
- environment and base URLs for the target environment
- the signed session / auth contract your host app must use
- sandbox access
- any required feature flags enabled for your app

If any of these are missing, pause the integration and request them from EIXAM before continuing.

## 1. Choose your SDK surface

Select the integration path that matches your product:

- Flutter
- Android
- iOS
- Web
- API / backend

If your app is Flutter-based, continue below and then open [Flutter Integration](./flutter-integration.md).

## 2. Add the package

```yaml
dependencies:
  eixam_connect_flutter: <version-provided-by-eixam>
```

Use the package version or distribution channel provided during your onboarding. Do not use local monorepo `path:` dependencies in a partner app.

## 3. Create the SDK

```dart
final sdk = await ApiSdkFactory.createHttpApi(
  apiBaseUrl: '<eixam-api-base-url>',
  websocketUrl: '<eixam-realtime-websocket-url>',
);
```

## 4. Provide the signed session

```dart
await sdk.setSession(
  EixamSession.signed(
    appId: '<your-app-id>',
    externalUserId: '<partner-user-id>',
    userHash: '<signed-session-value>',
  ),
);
```

The host app is responsible for supplying the signed session exactly as defined by the auth contract shared by EIXAM.

## 5. Subscribe to SDK state

```dart
sdk.currentSosStateStream.listen((state) {
  // render SOS state
});

sdk.deviceStatusStream.listen((status) {
  // render runtime device state
});
```

## 6. Build your UI on top of the SDK

Your app should use the SDK as the product logic layer:

- call public SDK methods from your screens and view models
- subscribe to SDK streams to render state
- keep UI, branding, and navigation in your host app
- use the official examples as implementation references

Next steps:

1. Open [Flutter Integration](./flutter-integration.md)
2. Review [Public API](./public-api.md)
3. Use [API Examples](./public-api-examples.md) to build your UI
