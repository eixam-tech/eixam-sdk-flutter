# AGENTS.md

## Architecture

EIXAM is a connected safety platform built SDK-first:

- `eixam_connect_core` — public contracts, entities, enums, domain models
- `eixam_connect_flutter` — runtime: BLE, persistence, protection, MQTT, permissions
- `eixam_control_app` — thin validation host, not the partner UX

## Product rules

1. Business-critical logic lives in the SDK/runtime layers, not in app widgets.
2. The control app exists to validate the SDK, not to define UX patterns.
3. UI decisions must not pollute SDK contracts.
4. BLE parsing, reconnect logic, and protection orchestration belong in runtime layers.

## Public bootstrap contract

```dart
final sdk = await EixamConnectSdk.bootstrap(
  const EixamBootstrapConfig(
    appId: 'partner-app',
    environment: EixamEnvironment.production,
  ),
);
```

- `production`, `sandbox`, `staging` resolve internally
- `custom` requires `EixamCustomEndpoints`; non-custom must not receive it
- `initialSession.appId` must match bootstrap `appId` when provided
- `bootstrap(...)` does not request permissions or trigger UX-sensitive actions

## BLE rules

- Validate device compatibility after connect + service discovery, not by advertised name alone.
- TEL aggregate reassembly belongs in `BleDeviceRuntimeProvider`, not the UI layer.
- SOS packet semantics belong in protocol/runtime layers.
- UI renders typed `BleIncomingEvent` state — it does not decode raw byte arrays.

## Realtime rule

Do not hardcode a final production WebSocket model until the backend protocol is finalized.
