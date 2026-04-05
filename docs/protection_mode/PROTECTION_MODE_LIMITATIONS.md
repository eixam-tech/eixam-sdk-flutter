# Protection Mode Limitations

## Global

- Protection Mode is optional and disabled by default.
- No auto-arm happens on startup.
- When Protection Mode is off, existing SDK behavior should remain unchanged.

## Partial vs Full

- `partial`
  - The additive Protection path is armed or scaffolded, but runtime ownership/readiness is incomplete.
- `full`
  - The platform runtime is the authoritative owner and reports ready-state signals for the armed flow.

## Current Android Guarantees

- The Android foreground service and bridge are SDK/plugin-owned.
- The platform reports explicit BLE owner/runtime/rehydrate diagnostics.
- Arming Protection Mode does not alter the default non-Protection path when the mode is off.

## Current Android Non-Guarantees

- Native Android BLE ownership readiness still depends on service BLE connection/subscription state progressing to ready.
- The current queue support is intentionally minimal and focused on Protection hooks, not a generic sync engine.

## Current iOS Guarantees

- The iOS adapter exists and participates safely in readiness, status, and diagnostics.
- The SDK reports honest degradation instead of claiming full support.

## Current iOS Non-Guarantees

- No full background BLE ownership yet
- No restoration-backed reattach/runtime recovery yet
- No promise of service-equivalent SOS lifecycle handling while the UI/runtime is absent
