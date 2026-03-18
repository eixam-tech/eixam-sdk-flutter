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
- BLE provider/runtime
- demo/bootstrap factories
- realtime skeleton or mock wiring

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

The project must remain **SDK-first**.

That means:

1. The SDK is the main product foundation.
2. The reference app exists to validate and demonstrate the SDK.
3. Business-critical logic should live in the SDK, not only in the demo app.
4. The Control app should consume the SDK like a real host app would.
5. UI decisions should not pollute SDK domain contracts.

---

## Current implemented modules

The repository already includes work on:

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
- BLE runtime/provider layer
- local persistence
- demo bootstrap flow
- realtime skeleton
- mock realtime client
- cached realtime state exposed through the public SDK API
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

## Current BLE status

BLE is no longer just conceptual. Current repo reality:

### What already works
- BLE scan on Android physical device
- BLE connection to a real device
- manual device selection is preferred over auto-picking candidates
- real device service discovery
- compatibility diagnostics after `discoverServices()`

### Current compatibility rule
Do **not** validate BLE devices by advertised name.

Do **not** assume a device is compatible just because scan sees it.

Compatibility must be validated only after:
1. BLE connect
2. `discoverServices()`

### Current firmware reality
The current real device exposes:
- EIXAM main service: `6ba1b218-15a8-461f-9fa8-5dcae273ea00`
- TEL notify characteristic: `6ba1b218-15a8-461f-9fa8-5dcae273ea01`
- SOS notify characteristic: `6ba1b218-15a8-461f-9fa8-5dcae273ea02`
- INET write characteristic: `6ba1b218-15a8-461f-9fa8-5dcae273ea03`

The CMD characteristic `...ea04` may be missing on the current firmware version.

### Soft compatibility rule
For now, treat the device as compatible enough to proceed if all of these are present:
- service `ea00`
- characteristic `ea01`
- characteristic `ea02`
- characteristic `ea03`

Treat `ea04` as optional for now.

Do not hard-fail the connection only because `ea04` is missing.
Instead, surface a warning in logs/UI.

### BLE behavior rules
#### Scan
- During BLE debug/testing, do not filter scan results by advertised device name
- Do not require advertised service UUIDs during scan
- Prefer broad scan + manual user selection
- Show discovered devices in UI when possible

#### Connect
- Do not auto-connect to arbitrary scan candidates during debug
- Let the user choose which device to connect to
- After manual selection:
  - connect
  - discover services
  - log everything
  - validate compatibility

#### Notifications
After successful connection to a compatible device:
- subscribe to TEL notify
- subscribe to SOS notify

#### Command writes
- Use INET when command size fits current firmware limitations
- If a command requires CMD and CMD is unavailable, show a precise warning/error
- Do not silently fail

---

## BLE logging requirements

When working on BLE, always log:
- adapter state
- scan results
- selected device
- connection start
- connection success/failure
- discovered services
- discovered characteristics
- characteristic properties:
  - read
  - write
  - writeWithoutResponse
  - notify
- notify subscription state
- last command sent
- last packet received
- compatibility result
- exact error when a connection or compatibility step fails

Validation should be diagnostic-first, not pass/fail-only.

---

## Android-specific rules

- Prioritize testing on physical Android devices, not emulator
- Ensure Android BLE permissions are correctly declared
- Ensure runtime Bluetooth permissions are handled
- If scan requires it on Android, be explicit about location/fine location requirements
- Keep Android install/debug workflows practical and scriptable

Preferred entrypoint from monorepo root:

```bash
flutter run -t apps/eixam_control_app/lib/main.dart