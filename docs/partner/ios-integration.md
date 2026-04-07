# iOS Host Integration

## Current State

- The SDK now includes an iOS Protection adapter and readiness/status/diagnostic participation.
- The implementation is intentionally honest: it is scaffolded, safe, non-crashing, and restoration-aware, but it does not claim full background BLE ownership yet.

## Host App Expectations

- Configure notification permissions UX.
- Prepare `UIBackgroundModes` for future support, especially `bluetooth-central`.
- Be ready for restoration/state-preservation callbacks and lifecycle handoff wiring as the native runtime hardens.

## What The SDK Owns Today

- iOS Protection method/event channel contract
- Base status and diagnostics reporting
- Restoration-configured reporting and last-restoration event diagnostics
- Honest degradation reason strings
- Participation in the same Dart Protection API as Android

## What Is Not Yet Implemented

- Background BLE ownership while armed
- Restoration-backed BLE reconnect/runtime recovery
- Service-equivalent lifecycle ownership for critical SOS flows
- Production-ready iOS Protection queue processing

## Readiness Interpretation

- `platformRuntimeConfigured=true`
  - The host can talk to the iOS Protection adapter.
- `backgroundCapabilityState=unknown`
  - The SDK cannot yet guarantee the host background BLE configuration is complete.
- `coverage=partial`
  - The iOS base path is wired, but runtime ownership is not complete.

## Troubleshooting

- If Protection Mode appears partial on iOS, that is expected with the current base implementation.
- If notifications or Bluetooth appear unavailable, inspect app permissions and capabilities first.
- Do not rely on iOS Protection Mode for background BLE ownership until the future runtime/restoration phase is implemented.
