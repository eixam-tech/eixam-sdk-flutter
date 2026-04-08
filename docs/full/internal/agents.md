# AGENTS.md

## Project overview

EIXAM is being built as a **connected safety platform** with an SDK-first approach.

The architecture is structured around:

- **EIXAM SOS Core**
- **EIXAM Connect SDK**
- **EIXAM Control App** (validation host)
- **Safety Dashboard** (future operational layer)

## Product rules

1. The SDK is the main product foundation.
2. The control app exists to validate and demonstrate the SDK.
3. Business-critical logic must live in the SDK/runtime layers.
4. The host app should remain thin.
5. UI decisions must not pollute SDK contracts.
6. BLE parsing, reconnect logic and protection orchestration belong in runtime layers.

## Public bootstrap rule

For partner-facing integration, the recommended public entrypoint is:

```dart
final sdk = await EixamConnectSdk.bootstrap(
  const EixamBootstrapConfig(
    appId: 'partner-app',
    environment: EixamEnvironment.production,
  ),
);
```

Additional bootstrap rules:

- `production`, `sandbox`, and `staging` resolve internally
- `custom` requires `EixamCustomEndpoints`
- non-custom environments must not receive `customEndpoints`
- `initialSession` is optional
- if `initialSession` is provided, its `appId` must match the bootstrap `appId`
- `bootstrap(...)` does not request permissions or trigger UX-sensitive actions

## Repository source of truth

Always work from the top-level monorepo root:

```text
C:\Users\roger\flutterdev\eixam_connect_sdk
```

## Documentation split

- `docs/partner/` → partner-facing source Markdown
- `docs/full/` → full/internal source Markdown
- `site/partner/` → generated partner HTML portal
- `site/full/` → generated full/internal HTML portal

## BLE engineering rules

- Do not validate compatibility by advertised BLE name alone.
- Validate compatibility only after connect + service discovery.
- TEL aggregate reassembly belongs in runtime/provider layers.
- SOS packet semantics belong in protocol/runtime layers.
- UI should render typed state, not decode raw byte arrays.

## Realtime rule

Realtime remains transport-sensitive and backend-contract-sensitive. Do not hardcode a final production WebSocket model until the backend protocol is finalized.
