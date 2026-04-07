# SDK Partner Integration Guide

## Purpose

This guide is for partner teams integrating the EIXAM SDK into a host app.

It focuses on:

- what the partner backend must provide
- how the host app should initialize the SDK
- how to use the public SDK facade v1
- what to expect from SOS, telemetry, contacts, and device surfaces

This guide is intentionally simpler than the internal technical integration document.

## What The Partner Backend Must Implement

The mobile SDK expects the partner/backend side to provide:

1. A signed SDK session for the mobile user
2. Backend support for `GET /v1/sdk/me`
3. Backend support for MQTT operational flows
4. Backend support for `POST /v1/sdk/sos/cancel`
5. Backend support for contacts and registered devices HTTP surfaces already agreed in OpenAPI

## Signed Session

The host app must supply a signed session to the SDK.

Minimum fields:

- `appId`
- `externalUserId`
- `userHash`

Example:

```dart
await sdk.setSession(
  const EixamSession.signed(
    appId: 'partner-app',
    externalUserId: 'partner-user-123',
    userHash: 'signed-token-or-hash',
  ),
);
```

Important:

- the SDK does not sign users locally
- the SDK does not call partner auth/sign endpoints on its own

## Canonical Identity

After `setSession(...)`, the SDK enriches identity through:

- `GET /v1/sdk/me`

This allows the SDK to:

- resolve canonical backend identity
- use the canonical external user id for MQTT topic building

If needed, the host app can explicitly refresh this state:

```dart
await sdk.refreshCanonicalIdentity();
```

This is an advanced operational call, not a separate login flow.

## SDK Initialization

Typical initialization flow:

```dart
final sdk = await ApiSdkFactory.createHttpApi(
  apiBaseUrl: 'https://api.example.com',
  websocketUrl: 'wss://mqtt.example.com/mqtt',
);

await sdk.setSession(
  const EixamSession.signed(
    appId: 'partner-app',
    externalUserId: 'partner-user-123',
    userHash: 'signed-token-or-hash',
  ),
);
```

The host app should stay thin. It should use SDK methods and streams, not implement operational backend logic itself.

## Public SDK Facade v1

Primary surfaces currently exposed:

### Identity / session

- `setSession(...)`
- `clearSession()`
- `refreshCanonicalIdentity()`

### SOS

- `triggerSos(SosTriggerPayload(...))`
- `cancelSos()`
- `currentSosStateStream`
- `lastSosEventStream`

### Telemetry

- `publishTelemetry(...)`

### Contacts

- `listEmergencyContacts()`
- `createEmergencyContact(...)`
- `updateEmergencyContact(...)`
- `deleteEmergencyContact(id)`

### Backend device registry

- `listRegisteredDevices()`
- `upsertRegisteredDevice(...)`
- `deleteRegisteredDevice(id)`

### Local device runtime

- `deviceStatusStream`
- `connectDevice(...)`
- `disconnectDevice()`
- `preferredDevice`

## SOS Flow

App-initiated SOS:

```dart
await sdk.triggerSos(
  const SosTriggerPayload(
    message: 'Need help',
    triggerSource: 'button_ui',
  ),
);
```

Current behavior:

- SOS publish goes over MQTT
- cancel goes over HTTP
- final lifecycle state still comes from MQTT events

That means:

- `cancelSos()` requests cancellation
- the final cancelled state is still determined by backend MQTT lifecycle updates

## Telemetry Flow

Telemetry is operational publish, not registry state.

Example:

```dart
await sdk.publishTelemetry(
  SdkTelemetryPayload(
    timestamp: DateTime.now().toUtc(),
    latitude: 41.38,
    longitude: 2.17,
    altitude: 8,
    deviceId: 'device-1',
  ),
);
```

The SDK also has internal BLE-to-backend telemetry bridging for runtime BLE TEL events.

## Contacts Usage

Contacts are backend-aligned 1:1.

Example:

```dart
await sdk.createEmergencyContact(
  name: 'Alice',
  phone: '+34123456789',
  email: 'alice@example.com',
  priority: 1,
);

final contacts = await sdk.listEmergencyContacts();
```

Current public contact fields:

- `id`
- `name`
- `phone`
- `email`
- `priority`
- `createdAt`
- `updatedAt`

## Backend Device Registry Usage

This is separate from local BLE runtime device status.

Example:

```dart
await sdk.upsertRegisteredDevice(
  hardwareId: 'hw-1',
  firmwareVersion: '1.2.3',
  hardwareModel: 'EIXAM R1',
  pairedAt: DateTime.now().toUtc(),
);

final devices = await sdk.listRegisteredDevices();
```

Use this surface for backend registry records, not live BLE runtime state.

## Runtime Device Usage

Use the runtime device surface for local operational state:

```dart
await sdk.connectDevice(pairingCode: 'PAIR-1234');

final preferred = await sdk.preferredDevice;

sdk.deviceStatusStream.listen((status) {
  // render connection/activation/runtime state
});
```

Use this for:

- current BLE/runtime status
- connected/paired/activated state
- preferred device behavior

Do not use it as backend registry data.

## Logout / Session Clear

On logout or partner session invalidation:

```dart
await sdk.clearSession();
```

Current behavior:

- clears the stored session
- disconnects MQTT runtime connectivity
- clears pending bridge-driven operational items
- prevents stale operational replay after logout

## Troubleshooting

### `E_SDK_SESSION_REQUIRED`

Meaning:

- a signed session is missing

Check:

- `setSession(...)` has been called
- the host app is not publishing SOS or telemetry before session setup

### `/v1/sdk/me` errors

Meaning:

- session enrichment failed

Check:

- auth headers are accepted by backend
- backend returns valid JSON user payload
- backend returns canonical `external_user_id`

### MQTT not connected / reconnecting

Meaning:

- operational publish is not currently available

Current SDK behavior:

- telemetry keeps only the latest pending sample
- SOS keeps one pending trigger
- both retry when MQTT becomes available again

### SOS cancel appears delayed

This is expected if backend has accepted HTTP cancel but MQTT lifecycle confirmation has not yet arrived.

HTTP cancel is transactional only. MQTT remains the final lifecycle source of truth.

## Current Integration Boundaries

Partner teams should assume the following are already internalized by the SDK:

- MQTT topic building
- BLE decode logic
- BLE runtime to backend bridge behavior
- offline operational buffering policy
- device-side confirmation commands

The host app should call the SDK facade and observe streams. It should not recreate backend operational logic in app widgets or screens.

## Current Open Points

- BLE SOS backend acknowledgment routing is deterministic in the current runtime bridge:
  local-origin SOS uses `SOS_ACK`, active relay-origin SOS uses `SOS_ACK_RELAY(nodeId)`, and unexpected relay ACK events are ignored with diagnostics
- BLE SOS packets without coordinates are not publishable as backend SOS trigger
- TEL aggregate payload publish is currently limited to aggregate-complete blobs
  that decode cleanly as one classic 10-byte TEL packet; richer cluster
  aggregates are intentionally not exposed as a stable partner contract yet
