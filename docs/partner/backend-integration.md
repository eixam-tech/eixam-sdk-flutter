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

## Authentication and signing flow for partners

1. the partner backend stores the app secret
2. the backend signs or obtains `userHash` for `appId` + `externalUserId`
3. `externalUserId` must be unique per app
4. the mobile app receives a signed session containing `appId`, `externalUserId`, and `userHash`
5. the SDK bootstraps with `appId` + `initialSession`, or receives the same signed session later through `setSession(...)`
6. the SDK reuses that same identity for both HTTP and MQTT

`/v1/auth/sign` is acceptable only for internal EIXAM staging validation. Partner production systems must implement the sign flow on their own backend.

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

## HTTP auth vs MQTT auth

HTTP remains unchanged:

- `X-App-ID: <appId>`
- `X-User-ID: <externalUserId>`
- `Authorization: Bearer <userHash>`

MQTT now uses broker username/password auth:

- `username = sdk:<appId>:<externalUserId>`
- `password = <userHash>`
- no `Bearer` prefix in MQTT
- clean session is enabled

The SDK keeps the current topics, payloads, QoS, retain behavior, and signed-session flow. The same signed identity is reused across HTTP and MQTT.

## Important note

The SDK does not call partner auth or signing routes on its own and does not compute the signature locally.

## Realtime transport note

Public field names remain `mqttUrl` / `websocketUrl` for now, but the actual realtime broker URI may be `ssl://`, `tls://`, `tcp://`, `ws://`, or `wss://` depending on the environment and client transport.
