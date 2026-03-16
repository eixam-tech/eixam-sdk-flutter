# EIXAM Connect Starter

Starter workspace for the EIXAM Connect SDK built with Dart and Flutter.

## Workspace structure

- `packages/eixam_connect_core`: domain contracts, entities, state machines and use cases
- `packages/eixam_connect_flutter`: Flutter implementations, repositories, controllers and factories
- `packages/eixam_connect_ui`: reusable UI components and default SDK texts
- `apps/eixam_control_app`: reference host app used to validate the SDK

## Current capabilities

- SOS flow with state machine and location snapshot best effort
- Tracking with permissions, stale detection and observable controller
- Emergency contacts with local persistence
- Death Man Protocol with local notifications and optional SOS escalation
- Local state persistence for SOS, tracking, contacts and Death Man

## Native integration

Before running the host app, review:

- `packages/eixam_connect_flutter/NATIVE_PERMISSIONS_CHECKLIST.md`

That file documents:
- Android Manifest requirements
- iOS `Info.plist` requirements
- notification setup notes
- background tracking notes
- explicit confirmation that `shared_preferences` does **not** require extra native permissions

## Recommended next steps

1. Wire real backend repositories for SOS, contacts and devices
2. Add websocket/realtime support
3. Add stronger persistence and encryption where needed
4. Expand the UI kit and move the reference app toward a real control app


## Device runtime abstraction

The starter now includes a `DeviceRuntimeProvider` abstraction. This keeps pairing, activation and refresh logic behind a replaceable boundary so a future BLE or backend runtime can be plugged in without changing the public SDK API.


## Bluetooth permission support

The SDK now exposes Bluetooth permission state and a runtime `requestBluetoothPermission()` API. Native Bluetooth declarations are still required in the host app manifest / plist. See `packages/eixam_connect_flutter/NATIVE_PERMISSIONS_CHECKLIST.md`.


## BLE runtime scaffold
- See `packages/eixam_connect_flutter/BLE_PROVIDER_INTEGRATION.md` for the current BLE-oriented runtime abstraction.
