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
- BLE transport/runtime
- trusted device persistence
- auto-connect / reconnect orchestration
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
6. BLE protocol parsing, device orchestration, and reconnect behavior should live in SDK/runtime layers, not in random app widgets.

---

## Source of truth documents

The BLE source of truth is the latest protocol documentation available in the repo.

Preferred references:
- `docs/eixam/07_BLE_APP_PROTOCOL.md` if present
- otherwise the latest repository-level BLE protocol document used by the current integration work

If code behavior or old assumptions differ from the current BLE protocol document, treat the protocol document as the intended contract and treat mismatches as:
- firmware mismatch
- stale implementation
- incomplete integration
- or temporary compatibility workaround

Other important technical references:
- `SDK_ARCHITECTURE.md`
- `README.md`
- `packages/eixam_connect_flutter/NATIVE_PERMISSIONS_CHECKLIST.md`
- `packages/eixam_connect_flutter/BLE_PROVIDER_INTEGRATION.md`
- `docs/eixam/01_SPRINT1_TEL_BLE_SOS.md` if present

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
- trusted BLE device persistence
- auto-connect / reconnect lifecycle
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
- reconnect strategy for production realtime
- message contract finalization

### Important rule
Do **not** implement the final WebSocket client contract blindly.
Wait until backend provides the agreed realtime protocol.

A lightweight skeleton is acceptable, but the final production client must follow backend definitions.

---

## Current BLE status

BLE is now in active real-device integration, not just conceptual scaffolding.

### What already works
- BLE scan on Android physical device
- BLE connection to a real device
- manual device selection is preferred over auto-picking candidates
- service discovery on real device
- subscription to TEL and SOS notifications
- app-to-device writes through INET
- internal device control/testing UI exists or is being expanded
- preferred/trusted device persistence
- auto-connect on app startup
- auto-connect on app resume
- foreground auto-reconnect after unexpected disconnects
- manual disconnect prevents unwanted auto-reconnect

### BLE source of truth
Use the latest `07_BLE_APP_PROTOCOL` document in the repo as the current contract.

### Current BLE protocol model
The protocol defines:

- Service `ea00`
- TEL notify `ea01`
- SOS notify `ea02`
- INET write `ea03`
- CMD write `ea04`

### TEL packets
TEL is **not limited to classic 10-byte packets anymore**.

Supported TEL input types may include:
- classic TEL packets of 10 bytes
- aggregate/fragment packets using opcode `0xD0`
  - byte 0 = `0xD0`
  - bytes 1..2 = total length
  - bytes 3..4 = offset
  - remaining bytes = fragment payload

Large TEL aggregate payloads must be reassembled in the runtime/provider layer, not in UI widgets.

### SOS packets
SOS is **not limited to just classic mesh packets anymore**.

Supported SOS input types may include:
- 10-byte SOS mesh packets
- 5-byte minimal SOS mesh packets
- 4-byte device control/event packets:
  - `0xE1` → manual/user deactivation event
  - `0xE2` → app cancel acknowledgement event

### App → device commands include
- `0x01` INET_OK
- `0x02` INET_LOST
- `0x03` POS_CONFIRMED
- `0x04` SOS_CANCEL
- `0x05` SOS_CONFIRM
- `0x06` SOS_TRIGGER_APP
- `0x07` SOS_ACK
- `0x08` SOS_ACK_RELAY
- `0x10` SHUTDOWN
- `0x20` PROVISION (future / not implemented)

### BLE compatibility rule
Do **not** validate BLE devices by advertised name.

Do **not** assume a device is compatible just because scan sees it.

Compatibility must be validated only after:
1. BLE connect
2. `discoverServices()`

### Protocol-first rule
BLE behavior should be implemented as:

1. BLE transport
2. packet decode / command encode
3. runtime events / orchestration
4. UI rendering and user actions

Do not let UI write raw byte arrays directly.
Do not spread protocol parsing across random widgets.

---

## BLE architecture direction

The preferred architecture is:

### A. BLE transport layer
Responsibilities:
- connect
- disconnect
- discover services
- subscribe TEL/SOS
- write INET/CMD

### B. Protocol layer
Responsibilities:
- decode classic TEL packets
- decode TEL aggregate fragments
- reassemble TEL aggregate payloads
- decode SOS mesh packets
- decode SOS device event packets
- encode device commands

Examples of explicit models/helpers that are encouraged:
- `EixamTelPacket`
- `EixamTelFragment`
- `EixamTelReassembler`
- `EixamSosPacket`
- `EixamSosEventPacket`
- `EixamDeviceCommand`
- packet decoder
- command encoder

### C. Runtime / orchestration layer
Responsibilities:
- consume decoded packets
- expose runtime state/events
- classify incoming packet kinds
- drive local notifications
- drive backend-facing actions
- decide when to send:
  - `POS_CONFIRMED`
  - `SOS_ACK`
  - `SOS_ACK_RELAY`
- manage trusted device behavior
- manage auto-connect / reconnect rules
- deduplicate repeated SOS events when needed

### D. UI layer
Responsibilities:
- render current state
- render last packets
- render BLE debug info
- render device control actions
- render connection state
- render reconnecting / disconnected / manual disconnect feedback

UI should not own protocol logic.

---

## BLE connection lifecycle rules

The SDK/runtime should support a **trusted device** model.

### Preferred device rules
- Only one preferred device is needed for now
- A device becomes preferred only after a successful connection
- Persist at least:
  - device identifier / remoteId
  - display name if available
  - last connected timestamp

### Auto-connect / reconnect rules
- On app startup:
  - if a preferred device exists and manual disconnect is not active, try auto-connect
- On app resume:
  - if a preferred device exists and the app is not connected, try auto-connect
- On unexpected disconnect in foreground:
  - retry with controlled backoff
- On manual disconnect:
  - disable auto-reconnect until the user explicitly connects again

### Important rule
Do **not** create overlapping connection attempts.

Startup auto-connect, resume auto-connect, manual connect, and reconnect retries must be coordinated through runtime/orchestration logic, not through independent UI triggers.

---

## BLE behavior rules

### Scan
- During BLE debug/testing, do not filter scan results by advertised device name
- Do not require advertised service UUIDs during scan
- Prefer broad scan + manual user selection
- Show discovered devices in UI when possible

### Connect
- Do not auto-connect to arbitrary scan candidates during debug
- Let the user choose which device to connect to initially
- After manual selection:
  - connect
  - discover services
  - log everything
  - validate compatibility
- If the device becomes trusted/preferred, future reconnects may use stored identifier-based logic

### Notifications / incoming packets
After successful connection:
- subscribe to TEL notify
- subscribe to SOS notify

Do not treat raw packet spam as business-level state automatically.
Prefer:
- decode packet
- publish runtime event
- derive only the minimum useful UI/runtime state

### Command writes
- Use INET when command size fits protocol/device limits
- Use CMD when payload requires it
- If CMD is missing on a specific device/firmware, surface this as a compatibility warning or implementation caveat, not as hidden behavior
- Do not silently fail

### Backend-related flows
Follow the protocol flow:

#### TEL
- receive TEL
- decode TEL
- if fragment, reassemble if needed
- send to backend if internet exists
- when backend confirms position, send `POS_CONFIRMED`

#### SOS
- receive SOS
- decode SOS
- classify whether it is:
  - mesh SOS packet
  - device event packet
- send to backend when appropriate
- when backend acknowledges:
  - if current device is origin → send `SOS_ACK`
  - if current device is relay → send `SOS_ACK_RELAY(nodeId LE)`

---

## SOS semantics rules

Use protocol semantics, not loose UI wording.

### Correct mappings
- `Resolve` should map to `SOS_CANCEL` (`0x04`) when the intended firmware action is cancel/resolve
- `Cancel` should map to `SOS_CANCEL` (`0x04`)
- `Trigger SOS` should map to `SOS_TRIGGER_APP` (`0x06`)
- `Confirm SOS` should map to `SOS_CONFIRM` (`0x05`)
- `Backend ACK` should map to `SOS_ACK` (`0x07`)
- `ACK Relay` should map to `SOS_ACK_RELAY` (`0x08`)

### Important meaning
`SOS_ACK` means:
- backend/rescue has acknowledged the SOS
- not “user saw the alert”

Do not label this action ambiguously as plain “Acknowledge” if the intended meaning is backend acknowledgment.

### Device-originated SOS control events
If firmware sends device event packets such as `0xE1` or `0xE2`, prefer protocol-aware state transitions instead of UI-only assumptions.

Examples:
- `0xE1` may indicate manual deactivation from the physical device
- `0xE2` may indicate successful cancel acknowledgement from the app/device flow

These events should update runtime/controller state explicitly.

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
- preferred device save/load decisions
- startup auto-connect attempts
- resume auto-connect attempts
- reconnect scheduling and outcome
- exact error when a connection or compatibility step fails

Validation should be diagnostic-first, not pass/fail-only.

---

## Local notification rules

Current direction:
- local notifications should be driven by meaningful device-originated events
- avoid packet-level spam
- avoid duplicate/repeated notifications when the device is just beeping or retransmitting the same situation
- never notify for app-originated actions unless explicitly required

The preferred pattern is:
- incoming device packet/event
- runtime event classification
- local notification decision

Not:
- UI-only heuristics
- raw packet = always notify forever

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