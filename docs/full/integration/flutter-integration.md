# Flutter Integration

## Recommended pattern

Create one SDK instance during app bootstrap and inject it into your app state or dependency container.

```dart
class AppBootstrapper {
  Future<EixamConnectSdk> createSdk(EixamSession session) {
    return EixamConnectSdk.bootstrap(
      EixamBootstrapConfig(
        appId: session.appId,
        environment: EixamEnvironment.sandbox,
        initialSession: session,
      ),
    );
  }
}
```

## Thin host-app rule

The host app should:

- own UX and navigation
- request permissions intentionally
- subscribe to SDK streams
- call SDK methods

The host app should not:

- recreate backend operational logic already owned by the SDK
- parse BLE protocol directly in widgets
- hardcode transport/topic logic

## Session refresh example

```dart
await sdk.setSession(
  const EixamSession.signed(
    appId: 'partner-app',
    externalUserId: 'partner-user-123',
    userHash: 'signed-session-hash-rotated',
  ),
);

await sdk.refreshCanonicalIdentity();
```

## Lifecycle recommendation

- bootstrap once per app start
- keep one live SDK instance
- update session explicitly when login/logout changes
- do not rebuild the SDK instance unnecessarily for ordinary UX events
