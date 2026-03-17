# AGENTS.md

## Project overview

EIXAM is being built as a **connected safety platform** with an SDK-first approach.

The current product architecture is based on:

- **EIXAM SOS Core** → core safety logic and domain contracts
- **EIXAM Connect SDK** → embeddable SDK for host apps
- **EIXAM Control App** → reference Flutter app used to validate the SDK
- **Safety Dashboard** → future operational/monitoring layer

This repository is not just a mobile app. It is the base monorepo for the SDK and its reference implementation.

---

## Repository source of truth

Always work from this repository root:

`C:\Users\roger\flutterdev\eixam_connect_sdk`

Do **not** work from duplicated nested copies such as:

`C:\Users\roger\flutterdev\eixam_connect_sdk\eixam-sdk`

The top-level monorepo is the real source of truth.

---

## Monorepo structure

- `apps/eixam_control_app` → Flutter reference host app for SDK validation
- `packages/eixam_connect_core` → core contracts, entities, enums, domain logic
- `packages/eixam_connect_flutter` → Flutter/platform implementations, runtime, persistence, BLE, permissions
- `packages/eixam_connect_ui` → UI helpers / reusable UI layer

### High-level package intent

#### eixam_connect_core
Contains:
- SDK public interfaces
- entities
- enums
- events
- config/session models
- domain state machines

#### eixam_connect_flutter
Contains:
- Flutter runtime SDK implementation
- repositories
- local persistence
- permissions
- BLE provider skeleton
- demo/bootstrap factories
- realtime mock wiring

#### eixam_connect_ui
Contains:
- reusable UI support for Flutter host apps
- demo/reference UI helpers

#### eixam_control_app
Contains:
- reference app used to manually validate the SDK
- demo screens for module verification
- not the final product architecture by itself

---

## Product architecture rules

The project should remain **SDK-first**.

That means:

1. The SDK is the main product foundation.
2. The reference app exists to validate and demonstrate the SDK.
3. Business-critical logic should live in the SDK, not only in the demo app.
4. The Control app should consume the SDK like a host app would.
5. UI decisions should not pollute SDK domain contracts.

---

## Current implemented modules

At the time of this document, the repository already includes work on:

- SOS module
- tracking module
- permissions
  - location
  - notifications
  - Bluetooth
- local notifications
- emergency contacts
- Death Man Protocol
- device module
- BLE provider skeleton
- local persistence
- demo bootstrap flow
- realtime skeleton
- mock realtime client
- cached realtime state exposed through public SDK API
- reference app validation surface

---

## Current realtime status

Realtime is currently **mock-based**.

What exists:
- `RealtimeConnectionState`
- `RealtimeEvent`
- `RealtimeClient`
- `MockRealtimeClient`
- realtime streams exposed by the public SDK API
- cached last realtime connection state
- cached last realtime event
- reference app validation section

What does **not** exist yet:
- production WebSocket transport
- final backend realtime protocol
- authentication handshake
- reconnect strategy
- message contract finalization

### Important rule
Do **not** implement the final WebSocket client contract blindly.
Wait until backend provides the agreed realtime protocol.

A lightweight skeleton is acceptable, but the final production client must follow backend definitions.

---

## BLE status

BLE is currently at skeleton/prototyping level.

What exists:
- BLE abstraction
- mock BLE client
- BLE runtime provider
- Bluetooth permissions wiring
- native permission checklist

What does **not** exist yet:
- final production BLE client implementation
- full provisioning flow against a real device
- full production pairing lifecycle

---

## Persistence status

Local persistence already exists for several modules.

Guidelines:
- restoration must be defensive
- invalid/transient persisted states must not break bootstrap
- restoring state must not replay invalid transitions
- bootstrap must remain resilient

---

## Demo app role

The reference app is used to validate:
- bootstrap
- permissions
- notifications
- tracking
- SOS
- device state
- Death Man flows
- emergency contacts
- realtime mock state

The demo app is useful, but it is **not** the final goal.
The SDK remains the priority.

---

## Development rules

### 1. Prefer SDK changes over demo-only changes
If a capability belongs to the SDK, implement it in the SDK first.

### 2. Keep code comments and technical docs in English
All shared code should remain internationally readable.

### 3. Keep commits small and coherent
Prefer small, meaningful commits over large mixed ones.

### 4. Do not invent backend contracts
If backend behavior is undefined, explicitly mark the implementation as mock, placeholder, or pending backend alignment.

### 5. Do not introduce duplicate paths or duplicate working copies
Use only the top-level monorepo.

### 6. Avoid hiding state inside UI
If state is meaningful for host apps, prefer exposing it through the SDK public contract.

### 7. Make bootstrap resilient
App startup should not fail because of stale persistence or optional runtime modules.

### 8. Favor explicit entrypoints
Use:
```bash
flutter run -t apps/eixam_control_app/lib/main.dart
```

### 9. Keep architecture modular
- enums in `src/enums`
- interfaces in `src/interfaces`
- events in `src/events`
- entities/models in their proper folders
- Flutter-specific implementation only in `eixam_connect_flutter`

### 10. Document what changes
If a new SDK capability is introduced, update documentation accordingly.

---

## Documentation rules

The repo should maintain these docs:

- `README.md` → project overview
- `RUN_PROJECT.md` → how to run the monorepo/reference app
- `SDK_ARCHITECTURE.md` → architecture and package responsibilities
- `AGENTS.md` → shared context and working rules for coding agents
- `NEXT_STEPS.md` → current roadmap, blockers and priorities
- `HOST_APP_INTEGRATION.md` → host app integration guidance
- `BLE_PROVIDER_INTEGRATION.md` → BLE/provider design notes
- `NATIVE_PERMISSIONS_CHECKLIST.md` → Android/iOS permission requirements

---

## Commit style

Recommended commit message style:

- `feat: ...`
- `fix: ...`
- `docs: ...`
- `refactor: ...`
- `chore: ...`

Examples:
- `feat: expose realtime streams through public SDK API`
- `feat: cache and expose latest realtime state through SDK`
- `docs: add English run guide for shared SDK project`

---

## Current priorities

The current priority is to continue strengthening the SDK.

### Priority order
1. Consolidate documentation
2. Keep the demo/reference app usable for validation
3. Continue SDK hardening
4. Wait for backend before final WebSocket integration
5. Revisit production BLE implementation when appropriate

---

## Deferred work waiting for backend

These areas should wait for backend alignment:

- final WebSocket realtime contract
- production realtime event schema
- auth/session coupling for realtime
- backend-driven state synchronization rules

---

## How to run the project

From the monorepo root:

```bash
flutter clean
flutter pub get
flutter run -t apps/eixam_control_app/lib/main.dart
```

---

## Final guidance for coding agents

When making changes in this repo:

- verify the correct repo root
- work on the SDK-first architecture
- avoid assumptions about missing backend contracts
- prefer explicit, documented changes
- keep the project stable and runnable
- use the reference app to validate SDK behavior
