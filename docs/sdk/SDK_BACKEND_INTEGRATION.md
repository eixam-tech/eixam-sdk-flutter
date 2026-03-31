# SDK Backend Integration

## Purpose

This document is the current source of truth for the EIXAM SDK to backend integration as implemented in this monorepo.

It focuses on:

- SDK-first architecture
- current mobile runtime behavior
- backend contracts already wired into the SDK
- operational resilience and current limitations

The reference app is a validation surface, not the architecture owner. Business and operational integration logic lives in the SDK packages.

## Architecture Overview

The current integration is split into four concerns:

1. Identity and session bootstrap
2. Operational backend connectivity
3. SDK runtime and BLE device orchestration
4. Domain-facing facade for host apps

At a high level:

- the partner backend signs the mobile session
- the SDK stores that signed session
- the SDK enriches the session through `GET /v1/sdk/me`
- the SDK uses canonical backend identity to build MQTT topics
- SOS trigger and telemetry publish are operational MQTT flows
- SOS cancel is a transactional HTTP flow
- BLE runtime events are decoded locally and translated to backend-facing actions by an internal bridge

## Package Responsibilities

### `packages/eixam_connect_core`

Contains:

- public SDK interfaces
- public domain entities
- enums
- events
- session/config models

### `packages/eixam_connect_flutter`

Contains:

- SDK implementation
- HTTP and MQTT integration
- BLE runtime/provider logic
- local stores
- internal orchestration layers
- offline/reconnect operational hardening

## Session And Identity Flow

### 1. Signed Session Comes From Partner Backend

The host app is expected to receive or retrieve a signed SDK session from its own backend or partner backend.

Current signed identity fields:

- `appId`
- `externalUserId`
- `userHash`

The SDK does not compute the signature locally and does not call partner signing endpoints.

### 2. SDK Stores The Signed Session

The host app calls:

```dart
await sdk.setSession(
  const EixamSession.signed(
    appId: 'app-demo',
    externalUserId: 'external-user-123',
    userHash: 'signed-token-or-hash',
  ),
);
```

The SDK persists that session locally and updates the runtime session context used by HTTP and MQTT layers.

### 3. SDK Enriches Identity Through `/v1/sdk/me`

After a signed session is configured, the SDK calls:

- `GET /v1/sdk/me`

This step resolves:

- canonical backend user identity
- `sdkUserId`
- canonical `user.external_user_id`

That canonical external user id is then stored in the SDK session.

### 4. MQTT Topics Use Canonical Identity

The host-provided `externalUserId` is used for authentication headers and MQTT connect properties.

The canonical backend external user id returned by `/v1/sdk/me` is used for user-scoped MQTT topics.

Current topic rules:

- SOS events subscription: `sos/events/{segment}`
- telemetry publish: `tel/{segment}/data`

The segment is encoded through the SDK MQTT topic segment utility. Raw external user ids must not be interpolated directly into MQTT paths.

## HTTP Contracts

## `/v1/sdk/me`

Purpose:

- enrich the session with canonical backend identity

Used by:

- SDK bootstrap
- explicit `refreshCanonicalIdentity()`

## SOS Cancel

Endpoint:

- `POST /v1/sdk/sos/cancel`

Behavior:

- transactional HTTP request
- auth headers only
- no request body
- used only to request cancellation

Important:

- final SOS lifecycle state still comes from MQTT events
- HTTP cancel does not become the lifecycle source of truth

## Devices

HTTP backend registry uses:

- `/v1/sdk/devices`

This is a backend registry surface, not the runtime BLE device state.

Mapped public domain shape:

- `id`
- `hardwareId`
- `firmwareVersion`
- `hardwareModel`
- `pairedAt`
- `createdAt`
- `updatedAt`

## Contacts

HTTP contacts are aligned 1:1 with backend.

Mapped public domain shape:

- `id`
- `name`
- `phone`
- `email`
- `priority`
- `createdAt`
- `updatedAt`

No SDK-only public contact fields remain in the integration contract.

## MQTT Operational Integration

## SOS Operational Path

Current operational SOS transport:

- publish to `sos/alerts`
- subscribe to `sos/events/{segment}`
- MQTT 5
- QoS 1
- retain `false`

Current publish payload includes at least:

- `timestamp`
- `latitude`
- `longitude`
- `altitude`

Current SDK behavior:

- BLE/runtime-originated valid SOS with coordinates can be translated into backend SOS trigger publish
- app-originated SOS trigger also uses the same operational SOS path
- final SOS lifecycle transitions are still interpreted from MQTT events

## Telemetry Operational Path

Current operational telemetry transport:

- publish to `tel/{segment}/data`
- MQTT 5
- QoS 1
- retain `false`

Current publish payload includes at least:

- `timestamp`
- `latitude`
- `longitude`
- `altitude`

Optional fields may include:

- `userId`
- `deviceId`
- runtime device battery metadata when available

Telemetry remains operational best-effort data. It is not device registry state.

## Runtime Device vs Backend Device Registry

This separation is an explicit architecture decision.

### Runtime Device

Runtime device state is BLE/local operational state exposed as `DeviceStatus`.

Examples:

- connection state
- activation state
- live signal
- live battery
- trusted/preferred device
- reconnect state

### Backend Device Registry

Backend device registry is HTTP-backed backend data exposed as `BackendRegisteredDevice`.

Examples:

- registry id
- hardware id
- firmware version
- hardware model
- paired timestamp

The SDK does not merge these two concepts.

## Contacts Alignment

Emergency contacts are backend-owned.

The SDK facade and repository contract now mirror backend exactly and do not expose legacy local-only flags such as `active`.

## BLE To Backend Operational Bridge

The current internal orchestration point is:

- `BleOperationalRuntimeBridge`

This component sits between:

- decoded BLE runtime events
- operational backend repositories
- device-side confirmation commands

It is responsible for:

- consuming decoded BLE TEL and SOS events
- deciding when backend publish should happen
- deciding when device-side confirmations should be sent
- isolating this logic from UI/controllers/widgets

### Current Inputs

The bridge consumes:

- decoded `BleIncomingEvent`
- realtime connection state
- backend realtime events
- current SDK session presence

### Current Outputs

The bridge can:

- publish telemetry through the telemetry repository
- publish SOS through the SOS repository
- send `POS_CONFIRMED`
- send `SOS_ACK`
- send `SOS_ACK_RELAY`

## Current Resilience And Offline Policies

## Connectivity Awareness

The runtime bridge is aware of whether operational publish is currently available based on:

- active session exists
- realtime connection state is `connected`

Other states are treated as operationally unavailable:

- `disconnected`
- `connecting`
- `reconnecting`
- `error`
- no active session

## Telemetry Offline Policy

Current policy:

- latest sample wins
- no unbounded queue

Behavior:

- when valid BLE TEL arrives while MQTT is unavailable, the bridge retains only one pending telemetry sample
- if newer TEL arrives before reconnect, it replaces the previous pending sample
- when MQTT becomes available again, the bridge publishes the latest pending sample once

This is intentionally best-effort, not lossless.

## SOS Offline Policy

Current policy:

- retain a single pending SOS trigger
- retry once connectivity is available again

Behavior:

- when valid BLE SOS arrives while MQTT is unavailable, the bridge retains one pending SOS item
- duplicates are deduplicated by runtime signature
- when MQTT becomes available again, the bridge retries that pending SOS publish once

## Reconnect And Session Coordination

Current guarantees:

- no overlapping flush attempts inside the bridge
- no unbounded offline queue
- `clearSession()` clears pending telemetry and pending SOS bridge state
- `setSession(...)` resets previous pending bridge state before the new session is used

This prevents stale operational items from an old session being replayed into a later one.

## Source Of Truth Rules

The following rules remain unchanged:

- SOS final lifecycle state comes from MQTT events
- HTTP cancel remains transactional only
- telemetry remains best-effort operational data
- runtime BLE state is not backend registry state

## Validation And Debugging

Recommended validation surfaces:

- SDK tests in `packages/eixam_connect_flutter/test/sdk/eixam_connect_sdk_impl_test.dart`
- reference app validation flows
- BLE debug UI and BLE debug registry logs

Practical debug checkpoints:

- signed session present
- `/v1/sdk/me` returning canonical identity
- MQTT connect state transitions
- correct MQTT topic usage
- BLE incoming packet decode
- bridge retain/flush behavior when offline
- backend confirmation events producing expected device commands

## Remaining Limitations And Open Points

### BLE SOS Relay Semantics

The bridge currently treats relay acknowledgment conservatively.

What is implemented:

- if backend realtime clearly indicates relay acknowledgment or includes a relay node id, the SDK sends `SOS_ACK_RELAY`

What remains open:

- the exact rule to infer relay-vs-origin directly from every BLE SOS situation is still not fully defined in the current backend/mobile docs

### Minimal SOS Packets Without Coordinates

Current MQTT SOS payload requires coordinates.

Therefore:

- BLE SOS packets without position are observable in runtime
- but are not publishable as backend SOS trigger in the current implementation

### TEL Aggregate Payloads

TEL aggregate fragments are decoded and reassembled in the BLE runtime.

However, the current bridge does not yet translate aggregate-complete payloads into operational telemetry publish because a final aggregate-to-telemetry contract is not yet documented as a stable backend integration rule.

### Offline Persistence

Current resilience is in-memory runtime hardening.

Not implemented in this iteration:

- persistent replay queue across app restart
- guaranteed delivery queue
- backlog synchronization with backend

These are future evolutions, not current guarantees.
