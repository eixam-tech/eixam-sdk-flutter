# SDK Overview

EIXAM Connect SDK is the embeddable integration layer of EIXAM's connected safety platform.

The partner-facing mental model is simple:

- bootstrap the SDK once
- provide a signed session from your backend
- request permissions from your own host-app UX when needed
- use SDK methods and streams to drive SOS, device, tracking and safety flows

## Happy path

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

## Bootstrap models

### `EixamEnvironment`

Supported values:

- `production`
- `sandbox`
- `staging`
- `custom`

### `EixamCustomEndpoints`

Use this only with `EixamEnvironment.custom`.

Example:

```dart
const EixamCustomEndpoints(
  httpBaseUrl: 'https://partner-api.example.com',
  mqttUrl: 'wss://partner-mqtt.example.com/mqtt',
)
```

### `EixamBootstrapConfig`

Recommended minimum:

- `appId`
- `environment`
- optional `initialSession`

Advanced optional knobs:

- `customEndpoints`
- `enableLogging`
- `networkTimeout`
- `defaultLocaleCode`

## Bootstrap guarantees

- standard environments resolve internally
- custom endpoints are validated
- mismatched restored sessions are cleared
- the SDK keeps control of session lifecycle semantics
- bootstrap does not request runtime permissions or perform device pairing on its own

## Main partner capabilities

- session lifecycle
- canonical identity refresh
- operational diagnostics
- Protection Mode
- device connection and BLE runtime
- backend device registry
- SOS lifecycle
- contacts
- permissions and local notifications
- tracking and telemetry
- Death Man
- realtime status and events


## Internal note

The validation app may still use internal factory/bootstrap composition for environment switching and diagnostics. That does not change the recommended public partner entrypoint.
