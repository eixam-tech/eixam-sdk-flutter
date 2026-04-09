# Migration

## Migration to the single-call bootstrap flow

The recommended public integration flow changed from a multi-step setup to a single-call bootstrap.

## Previous pattern

```dart
final sdk = await ApiSdkFactory.createHttpApi(
  apiBaseUrl: 'https://partner-api.example.com',
  websocketUrl: 'ssl://partner-mqtt.example.com:8883',
);

await sdk.initialize(
  const EixamSdkConfig(
    apiBaseUrl: 'https://partner-api.example.com',
    websocketUrl: 'ssl://partner-mqtt.example.com:8883',
  ),
);

await sdk.setSession(
  const EixamSession.signed(
    appId: 'partner-app',
    externalUserId: 'partner-user-123',
    userHash: 'signed-session-hash',
  ),
);
```

## Recommended pattern now

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

## Migration rules

- prefer `bootstrap(...)` for new integrations
- keep `setSession(...)`, `clearSession()`, and `getCurrentSession()` for session lifecycle
- use `custom` only with `EixamCustomEndpoints`
- do not pass `customEndpoints` when using `production`, `sandbox`, or `staging`
- if you pass `initialSession`, ensure the `appId` matches the bootstrap `appId`
- the `websocketUrl` / `mqttUrl` field names stay stable for now even when the realtime URI is `ssl://`, `tls://`, `tcp://`, `ws://`, or `wss://`

## MQTT auth migration

HTTP auth is unchanged:

- `X-App-ID: <appId>`
- `X-User-ID: <externalUserId>`
- `Authorization: Bearer <userHash>`

MQTT auth now uses broker-compatible credentials instead of MQTT 5 User Properties:

- `username = sdk:<appId>:<externalUserId>`
- `password = <userHash>`
- no `Bearer` prefix in the MQTT password
- clean session remains enabled

This migration does not change the signed-session shape, MQTT topics, payloads, QoS, retain behavior, or the rule that the app secret stays on the backend only.

## SOS payload note

Operational SOS payloads may include optional `deviceId` when the SDK knows the paired device hardware id.

- hardware-originated SOS should send `deviceId = hardware_id` when available
- app-originated SOS without a paired device may omit `deviceId`
- telemetry keeps using `deviceId = hardware_id` when available

## What bootstrap does not do

- it does not request permissions
- it does not pair devices
- it does not start tracking
- it does not trigger Protection Mode automatically
