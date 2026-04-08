# SDK Backend Integration

## Purpose

This document is the current source of truth for SDK-to-backend integration behavior in the monorepo.

## Integration layers

1. partner-provided signed identity
2. bootstrap/environment resolution
3. canonical identity enrichment
4. operational transport for SOS/telemetry
5. transactional HTTP surfaces
6. local BLE/runtime orchestration

## Signed session model

Current signed identity fields:

- `appId`
- `externalUserId`
- `userHash`

The SDK does not compute these values locally.

## Bootstrap model

The public Flutter bootstrap path is:

```dart
final sdk = await EixamConnectSdk.bootstrap(
  const EixamBootstrapConfig(
    appId: 'partner-app',
    environment: EixamEnvironment.production,
  ),
);
```

Environment rules:

- `production`, `sandbox`, `staging` resolve internally
- `custom` requires `EixamCustomEndpoints`
- mismatched restored sessions are cleared

## Canonical identity

After a valid signed session is available, the SDK may call `GET /v1/sdk/me` to resolve canonical identity used by runtime/transport layers.

## HTTP contracts

### `GET /v1/sdk/me`

Enriches the session with canonical backend identity.

### `GET /v1/sdk/sos`

Rehydrates runtime SOS state on bootstrap/startup/refresh.

### `POST /v1/sdk/sos/cancel`

Transactional cancel request. Final lifecycle state still depends on runtime lifecycle events.

### `/v1/sdk/devices`

Backend registry surface for devices.

### Contacts surface

Backend-aligned CRUD surface for contacts.

## Operational transport

- SOS trigger uses operational transport
- telemetry publish uses operational transport
- host apps should not bypass SDK topic/transport conventions

## Internal note

The validation app may still expose internal backend configuration controls, but those are not part of the partner happy path.
