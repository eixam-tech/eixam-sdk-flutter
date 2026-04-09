# API Reference

This page summarizes the backend-facing contracts a partner integration should expect.

## Identity

Partner/backend signing responsibility:

- the backend stores the app secret
- the mobile app receives a signed session only
- the SDK does not compute `userHash` locally or own the app secret
- internal staging validation may use `/v1/auth/sign`, but partner production signing belongs on the backend

### `GET /v1/sdk/me`

Used by the SDK to enrich the signed session with canonical backend identity.

## SOS

### `POST /v1/sdk/sos/cancel`

Transactional cancel request.

Notes:

- no business meaning should be inferred from the HTTP response alone
- final SOS lifecycle state still comes from the operational runtime lifecycle

### `GET /v1/sdk/sos`

Used for SOS rehydration on startup/bootstrap and identity refresh.

## Devices

### `/v1/sdk/devices`

Backend device registry surface.

Mapped public shape:

- `id`
- `hardwareId`
- `firmwareVersion`
- `hardwareModel`
- `pairedAt`
- `createdAt`
- `updatedAt`

## Contacts

Contacts are aligned 1:1 with the backend contract:

- `id`
- `name`
- `phone`
- `email`
- `priority`
- `createdAt`
- `updatedAt`

## Operational transport

The SDK also relies on operational transport for SOS/telemetry flows. Topic naming and exact transport details should remain aligned with the backend contract, not hardcoded independently by the host app.

The configured broker URI may be `ssl://`, `tls://`, `tcp://`, `ws://`, or `wss://` depending on environment and transport client.
