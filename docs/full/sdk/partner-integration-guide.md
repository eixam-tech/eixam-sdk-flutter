# SDK Partner Integration Guide

This guide is the full internal version of the partner integration story.

## Public recommendation

For partner integrations, the recommended entrypoint is:

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

## Why the single-call bootstrap is better

It gives partners a cleaner happy path than exposing `createHttpApi + initialize + apply/setSession` as the main story.

## Validation rules

- standard environments resolve internally
- `custom` requires `EixamCustomEndpoints`
- non-custom environments reject `customEndpoints`
- `initialSession.appId` must match the bootstrap `appId`
- bootstrap does not request permissions, pair devices, or trigger other UX-sensitive actions

## Session lifecycle after bootstrap

The recommended lifecycle surfaces remain:

- `setSession(...)`
- `clearSession()`
- `getCurrentSession()`
- `refreshCanonicalIdentity()`

## Internal distinction

- partner path → `EixamConnectSdk.bootstrap(...)`
- validation app path → internal bootstrapping composition and environment controls
