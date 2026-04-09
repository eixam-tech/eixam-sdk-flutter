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

## Signed Session And Backend Responsibilities

- the partner backend stores the app secret
- the app secret never belongs in the mobile client
- the backend signs or obtains `userHash` for `appId` + `externalUserId`
- `externalUserId` must be unique per app
- the mobile app receives the signed session and passes it to bootstrap or `setSession(...)`
- the SDK then reuses the same identity for HTTP and MQTT/runtime transport
- internal staging validation may use `/v1/auth/sign`, but partner production signing must stay on the backend

HTTP auth remains `X-App-ID`, `X-User-ID`, and `Authorization: Bearer <userHash>`.

MQTT auth now uses `username = sdk:<appId>:<externalUserId>` and `password = <userHash>`, without a `Bearer` prefix.

## Validation rules

- standard environments resolve internally
- `custom` requires `EixamCustomEndpoints`
- non-custom environments reject `customEndpoints`
- `initialSession.appId` must match the bootstrap `appId`
- bootstrap does not request permissions, pair devices, or trigger other UX-sensitive actions
- the public `mqttUrl` / `websocketUrl` naming stays stable even when the broker URI is `ssl://`, `tls://`, `tcp://`, `ws://`, or `wss://`

## Session lifecycle after bootstrap

The recommended lifecycle surfaces remain:

- `setSession(...)`
- `clearSession()`
- `getCurrentSession()`
- `refreshCanonicalIdentity()`

## Internal distinction

- partner path → `EixamConnectSdk.bootstrap(...)`
- validation app path → internal bootstrapping composition and environment controls
