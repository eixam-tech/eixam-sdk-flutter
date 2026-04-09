# Backend Integration

## What the partner backend must provide

The host app is expected to rely on a partner/backend service that provides:

1. a signed SDK session
2. canonical identity support through `GET /v1/sdk/me`
3. MQTT operational support for SOS and telemetry
4. transactional HTTP support for SOS cancel
5. contacts and backend device registry surfaces

## Signed Session And Backend Responsibilities

- the partner backend stores the app secret
- the app secret never belongs in the client
- the backend generates or obtains `userHash` for `appId` + `externalUserId`
- `externalUserId` must be unique per app
- the mobile app receives a signed session
- the SDK reuses that same identity for both HTTP and MQTT/runtime transport
- `/v1/auth/sign` is acceptable for internal staging validation only
- real partner integrations must implement the server-side sign flow in the partner backend

## Signed session contract

Minimum fields:

- `appId`
- `externalUserId`
- `userHash`

Example:

```dart
const EixamSession.signed(
  appId: 'partner-app',
  externalUserId: 'partner-user-123',
  userHash: 'signed-session-hash',
)
```

## Bootstrap and session

If the host app already has a signed session at startup, pass it as `initialSession` in the bootstrap config.

If not, bootstrap without a session and call `setSession(...)` later.

Recommended bootstrap shape:

```dart
final sdk = await EixamConnectSdk.bootstrap(
  const EixamBootstrapConfig(
    appId: 'partner-app',
    environment: EixamEnvironment.production,
    initialSession: EixamSession.signed(
      appId: 'partner-app',
      externalUserId: 'partner-user-123',
      userHash: 'signed-session-hash',
    ),
  ),
);
```

## Current operational model

- session enrichment: HTTP `GET /v1/sdk/me`
- SOS trigger: operational transport
- SOS cancel: HTTP `POST /v1/sdk/sos/cancel`
- active SOS rehydration: `GET /v1/sdk/sos`
- telemetry: operational transport
- registered devices and contacts: HTTP surfaces

## Important note

The SDK does not call partner auth or signing routes on its own and does not compute the signature locally.

## Realtime transport note

Public field names remain `mqttUrl` / `websocketUrl` for now, but the actual realtime broker URI may be `ssl://`, `tls://`, `tcp://`, `ws://`, or `wss://` depending on the environment and client transport.
