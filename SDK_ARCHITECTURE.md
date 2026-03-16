# EIXAM Connect SDK — Project Documentation

## 1. Purpose of this document

This document consolidates the current state of the **EIXAM Connect SDK** project.

It is intended to be the main technical and product reference for the team until backend contracts, realtime protocol details and production integration details are fully defined.

It covers:

- product scope
- architecture
- module breakdown
- current implementation status
- demo/reference app scope
- permissions and native integration
- BLE and realtime foundations
- recommended next steps
- current technical decisions already aligned

---

## 2. Project overview

EIXAM is being developed as an **SDK-first safety platform** in **Flutter/Dart**.

The current strategy is:

1. build a reusable SDK with the minimum but real safety capabilities
2. validate the SDK using a reference mobile app
3. evolve the same app into the internal **Control App**
4. later connect it with backend, dashboard and device ecosystem

### Current validated architecture

The working architecture is:

- **EIXAM SOS Core**
- **EIXAM Connect SDK**
- **EIXAM Control App** (reference/demo host app)
- **Safety Dashboard** (future operational layer)

### Product philosophy

The SDK must be:

- installable in host apps
- modular
- parametric
- reusable across clients and app shells
- compatible with future backend and device connectivity
- built with real runtime behavior, not just placeholder contracts

---

## 3. Main product scope of the SDK

The SDK currently targets the following core capabilities:

### 3.1 SOS

The SDK must allow host apps to:

- trigger SOS
- cancel SOS
- monitor SOS state
- attach best-effort location snapshot to SOS

### 3.2 Tracking

The SDK must allow host apps to:

- request device location permissions
- start tracking
- stop tracking
- receive current position and state updates
- detect stale positioning situations

### 3.3 Permissions

The SDK must orchestrate:

- location permissions
- notification permissions
- Bluetooth permissions
- Bluetooth enabled / disabled state awareness

### 3.4 Death Man Protocol

The SDK must support the standard “Death Man Protocol” logic:

- expected return time
- grace period
- confirmation window
- local notification prompts
- check-in confirmation
- escalation
- optional automatic SOS trigger

### 3.5 Emergency Contacts

The SDK must expose methods for:

- listing emergency contacts
- adding contacts
- updating contacts
- activating / deactivating contacts
- removing contacts

At this stage, the SDK is focused on **methods and persistence**, not host UI implementation.

### 3.6 Device integration

The SDK must prepare the base for EIXAM safety devices:

- pairing
- activation
- status monitoring
- provisioning lifecycle
- BLE integration readiness

### 3.7 Realtime

The SDK must prepare for realtime communication with backend or infrastructure, including:

- connection state
- event streams
- future WebSocket transport
- future SOS/device state synchronization

---

## 4. Current package structure

The project is currently organized as a monorepo with a top-level structure similar to:

- `apps/eixam_control_app`
- `packages/eixam_connect_core`
- `packages/eixam_connect_flutter`
- `packages/eixam_connect_ui`

### Package roles

#### `eixam_connect_core`
Contains:

- domain entities
- enums
- interfaces/contracts
- state machines
- SDK interface
- errors
- domain-level use cases

#### `eixam_connect_flutter`
Contains:

- Flutter runtime implementations
- repositories
- local persistence
- permission adapters
- notifications implementation
- device/BLE runtime providers
- SDK factories
- SDK implementation

#### `eixam_connect_ui`
Contains:

- reusable UI scope
- localization surface
- future reusable widgets/components for host apps

#### `apps/eixam_control_app`
Contains:

- reference/demo host app
- validation surface for SDK modules
- current testing playground for integration flows

---

## 5. Current implementation status

Below is the current status of the SDK by module.

### 5.1 SOS module

#### Implemented

- SOS public methods in SDK
- SOS state machine
- trigger flow
- cancel flow
- SOS repositories
  - in-memory version
  - API-ready version
- best-effort location snapshot attachment
- persisted state support
- defensive bootstrap behavior in demo mode

#### Notes

- SOS persistence has already caused bootstrap issues in the past and was stabilized defensively in the demo setup
- runtime transitions are implemented
- persisted transitional states required special care

#### Current maturity

**Good for SDK prototype / internal validation**

---

### 5.2 Tracking module

#### Implemented

- location permission flow
- tracking start/stop
- current position retrieval
- tracking state stream
- positions stream
- stale detection foundations
- persistence of last known tracking-related state

#### Notes

- real device positioning is already wired
- host app must still declare native permissions properly

#### Current maturity

**Good for SDK prototype / reference app validation**

---

### 5.3 Permissions module

#### Implemented

- location permission request
- notification permission request
- Bluetooth permission request
- Bluetooth enabled awareness
- unified `PermissionState`

#### Native integration documented

Permissions and native requirements have already been documented for:

- Android Manifest
- iOS Info.plist
- host app responsibilities

#### Current maturity

**Good and already useful for integration**

---

### 5.4 Notifications module

#### Implemented

- local notifications initialization
- local notification display
- integration with Death Man flows
- integration with permission flow

#### Current maturity

**Good for prototype and internal validation**

---

### 5.5 Death Man Protocol module

#### Implemented

- plan scheduling
- monitoring logic
- grace period handling
- check-in window handling
- local notifications during escalation
- confirm safe
- cancel plan
- optional automatic SOS escalation
- active plan retrieval
- plan stream
- persistence support

#### Notes

- this is already a real implementation, not just a concept
- it is one of the strongest parts of the SDK foundation at this stage

#### Current maturity

**Strong prototype / good internal MVP base**

---

### 5.6 Emergency Contacts module

#### Implemented

- list contacts
- watch contacts
- add contact
- update contact
- activate/deactivate contact
- remove contact
- persistence support

#### Notes

- the SDK intentionally focuses on methods and persistence, not host UI
- host app is responsible for final UX

#### Current maturity

**Good for internal MVP and integration**

---

### 5.7 Device module

#### Implemented

- device status entity
- device lifecycle concept
- pair device
- activate device
- refresh device status
- unpair device
- watch device status
- provisioning error field
- runtime/provider abstraction
- persistence support

#### Notes

- this is not yet a real BLE implementation
- but it is no longer a placeholder either
- the domain and lifecycle foundations are already in place

#### Current maturity

**Good base for next BLE and provisioning phases**

---

### 5.8 BLE foundation

#### Implemented

- Bluetooth permission support
- Bluetooth enabled awareness
- BLE provider abstraction
- `BleClient` contract
- `MockBleClient`
- `BleDeviceRuntimeProvider`
- BLE integration documentation

#### Notes

- real BLE plugin integration has not yet started
- the architecture is prepared to integrate something like a real Flutter BLE client later

#### Current maturity

**Architecture ready, runtime still mock-based**

---

### 5.9 Realtime foundation

#### Implemented

- `RealtimeConnectionState`
- `RealtimeEvent`
- `RealtimeClient` contract
- `MockRealtimeClient`
- integration in SDK initialization flow
- public realtime API in `EixamConnectSdk`
- latest realtime state cache in SDK implementation
- latest realtime event cache in SDK implementation
- demo validation widget showing realtime state and last event

#### Notes

- realtime is currently mock-based
- WebSocket transport has intentionally been postponed until backend defines the protocol and expectations clearly

#### Current maturity

**Good skeleton, not yet backend-connected**

---

## 6. Localization / internationalization

The SDK is being designed to be multilingual.

### Current target languages

- Spanish (default)
- English
- Catalan
- French

### Agreed principles

- SDK must be parametric
- texts must be overridable
- SDK may provide defaults
- host apps must be able to replace texts when needed

### Current status

- the direction is validated
- foundations were already introduced
- more systematic localization work will still be needed as the UI surface grows

---

## 7. Persistence strategy

The current persistence layer is intentionally simple but useful.

### Implemented persistence scope

Persistence support exists for:

- SOS state / incident
- tracking state / last known position
- Death Man active plan
- emergency contacts
- device status

### Current storage approach

- `SharedPreferences`
- simple serializers
- local restore during bootstrap where applicable

### Important notes

- `SharedPreferences` does **not** require extra Android/iOS privacy permissions by itself
- current persistence is suitable for prototype and internal MVP stage
- sensitive or critical production data may later require:
  - stronger storage
  - encryption
  - sync conflict handling
  - offline queues

---

## 8. Native integration requirements

The host app must declare the necessary native permissions and capabilities.

### Already documented

The project already has documentation/checklists covering:

- Android location permissions
- Android notification permissions where applicable
- Android Bluetooth permissions
- iOS location usage descriptions
- iOS Bluetooth usage description
- notes for future background modes if needed

### Important architectural rule

The SDK may:

- request permissions at runtime
- expose permission state
- react to permission constraints

But the **host app** is still responsible for:

- native manifest/plist declarations
- platform capabilities
- proper packaging and release configuration

---

## 9. Reference app / Control App status

The current app is a **reference/demo host app** used to validate the SDK.

### Current role

- bootstrap the SDK
- prove module integration works
- validate permissions/tracking/SOS/device/death man/realtime/contact flows
- serve as internal development playground

### Important note

The current demo app is not yet the final UX or final product implementation.
It is primarily:

- a validation surface
- an SDK host
- a technical integration app

It can evolve later into the internal **Control App** foundation.

---

## 10. Existing documentation files

At the moment there are already several `.md` files in the project that document specific integration areas.

One already identified by the team is:

- `eixam_connect_flutter/BLE_PROVIDER_INTEGRATION.md`

There are also other Markdown files already created across the project to document:

- native permissions
- host app integration
- BLE/provider behavior
- integration assumptions

### Recommended documentation approach from now on

Instead of keeping knowledge fragmented, the project should follow this structure:

#### A. One main SDK overview document
Recommended file:

- `SDK_PROJECT_DOCUMENTATION.md` or `EIXAM_CONNECT_SDK_DOCUMENTATION.md`

This document should be the single top-level reference.

#### B. Supporting focused docs
Keep focused documents for implementation details such as:

- BLE provider integration
- native permissions checklist
- host app integration guide
- realtime transport guide
- backend contract guide (future)

#### C. README role
The root README should remain shorter and point to the main detailed docs.

---

## 11. Recommended documentation map

A good final structure could be:

### Root level
- `README.md`
- `EIXAM_CONNECT_SDK_DOCUMENTATION.md`

### Flutter package docs
- `packages/eixam_connect_flutter/BLE_PROVIDER_INTEGRATION.md`
- `packages/eixam_connect_flutter/NATIVE_PERMISSIONS_CHECKLIST.md`
- `packages/eixam_connect_flutter/HOST_APP_INTEGRATION.md`

### Future docs
- `packages/eixam_connect_flutter/REALTIME_INTEGRATION.md`
- `packages/eixam_connect_flutter/DEVICE_PROVISIONING.md`
- `packages/eixam_connect_flutter/BACKEND_CONTRACTS.md`

---

## 12. Technical decisions already aligned

The following decisions are already effectively aligned and validated through the work done so far:

### 12.1 SDK-first strategy
The SDK is the core product layer.

### 12.2 Flutter/Dart as main implementation stack
The SDK and reference app are being built in Flutter/Dart.

### 12.3 Multilingual and overridable SDK texts
The SDK must support default texts and host-level overrides.

### 12.4 SOS, Tracking and Death Man are core MVP pillars
These are not optional side modules; they are central to the product.

### 12.5 Emergency contacts belong to SDK methods, not SDK-owned host UI
The SDK provides behavior and persistence; the host app owns UX.

### 12.6 Device integration requires BLE readiness from day one
Even before real BLE implementation, the architecture must anticipate it.

### 12.7 Realtime should be architected now, but real transport should wait for backend definition
This is the current agreed stance.

### 12.8 Demo app is a validation host, not the final product UX
It is useful, but it is not the final app experience.

---

## 13. Current limitations / not yet done

This section is important to keep expectations realistic.

### 13.1 Backend realtime protocol not defined yet
Therefore, the WebSocket client should wait for backend contract clarity.

### 13.2 BLE real client not implemented yet
The project is ready for it architecturally, but still mock-based.

### 13.3 API HTTP datasource contract still needs alignment
At least some HTTP datasource details remain to be stabilized against backend expectations.

### 13.4 Persistence is prototype-level, not yet final production-grade
Encryption, stronger storage and sync robustness may be needed later.

### 13.5 Demo app still mixes validation UI with technical testing UI
This is acceptable now, but should be cleaned up later.

### 13.6 Automated testing coverage is not yet a strong focus
Unit/integration tests will become increasingly important.

---

## 14. Recommended next steps

Given the current state, the recommended next steps are:

### Option A — Documentation consolidation
- finalize this main SDK documentation
- align the existing `.md` files around it
- keep technical docs focused and non-duplicated

### Option B — Realtime pause / backend alignment
- wait for backend contract before implementing WebSocket client
- define protocol, auth model, event types and reconnect expectations

### Option C — Continue SDK hardening in parallel
Without waiting for WebSocket, useful next work could still include:

- cleanup/refactor of demo app files
- testing strategy
- better SDK docs and comments
- stronger persistence rules
- device module refinement
- BLE client contract preparation

### Recommended sequence

1. consolidate documentation now
2. keep realtime transport pending until backend definition exists
3. continue SDK hardening in parallel
4. re-enter realtime once backend contract is available

---

## 16. Proposed commit messages for documentation work

If this documentation is added now, a good commit message would be:

```bash
feat: add consolidated SDK project documentation
```

If in the same pass you also clean or align existing Markdown docs:

```bash
docs: consolidate SDK architecture and integration documentation
```

---

## 17. Final status summary

At this moment, the EIXAM Connect SDK is already a serious prototype foundation with:

- real SOS flows
- real tracking flows
- permissions orchestration
- local notifications
- Death Man Protocol implementation
- emergency contacts management
- local persistence
- device lifecycle foundations
- BLE architecture skeleton
- realtime public API with mock transport
- working reference/demo app

The project is no longer at concept stage.
It is now at a **structured internal MVP / technical foundation stage**.

The next major milestone should be driven by:

- documentation consolidation
- backend contract clarity
- and controlled evolution from mock integrations to real transport layers

