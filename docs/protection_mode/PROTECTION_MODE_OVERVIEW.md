# Protection Mode Overview

Protection Mode is an optional additive SDK capability that arms a higher-resilience runtime for critical BLE and SOS handling without changing the default SDK behavior when it is left off.

## Goals

- Keep current BLE, SOS, telemetry, validation, and device flows unchanged unless `enterProtectionMode()` is called.
- Move platform-specific Protection ownership into the SDK/plugin layer as much as possible.
- Make Android the primary platform for foreground-service-backed ownership while the mode is armed.
- Include iOS now with honest scaffolding, readiness reporting, and host integration guidance instead of pretending full support already exists.

## Architecture

- `eixam_connect_core`
  - Protection public models and additive status/diagnostic contracts.
- `eixam_connect_flutter`
  - Protection controller, default platform adapter selection, Android native plugin bridge/service, iOS base adapter/scaffolding.
- Host app
  - App target capabilities, permissions UX, bootstrap, and validation UI consumption.

## SDK-Owned Responsibilities

- Public Protection API
- Protection readiness/status/diagnostics
- BLE owner reporting
- Android foreground service bridge and merged manifest service declaration
- Android runtime state persistence and rehydrate snapshot bridge
- Queue flush hook surface
- iOS readiness/base platform adapter scaffolding

## Host-Required Responsibilities

- App-level permission onboarding
- Android/iOS app capabilities and platform packaging requirements
- SDK bootstrap and validation UI
- Future iOS lifecycle/restoration integration

## Coverage Model

- `none`
  - Protection Mode is off or the platform runtime is unavailable.
- `partial`
  - Protection Mode is armed, but the platform runtime is degraded or only partially implemented.
- `full`
  - Protection Mode has the expected platform runtime ownership and readiness signals.

## Current Android State

- Android Protection runtime wiring is now SDK/plugin-owned instead of validation-app-owned.
- The plugin merges the foreground service declaration and exposes explicit BLE owner/runtime diagnostics.
- When Protection Mode is armed, the intended owner is `androidService`; readiness advances with service BLE connection/subscription signals.
- The current implementation persists state, ownership, queue counters, wake/reconnect metadata, and service events for rehydrate flows.

## Current iOS State

- iOS now participates in the same public contract.
- The plugin reports platform/runtime readiness and honest degradation.
- Full iOS background BLE ownership, restoration, and backend-safe lifecycle handling are not implemented yet.

## Roadmap

- Complete Android native BLE runtime ownership and service-side SOS lifecycle handling.
- Add iOS background BLE central, restoration, and lifecycle handoff support.
- Expand store-and-forward beyond the current minimal Protection queue hooks only when backend protocol contracts are ready.
