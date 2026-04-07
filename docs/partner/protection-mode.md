# Protection Mode

Protection Mode is an optional additive SDK capability that arms a higher-resilience runtime for critical BLE and SOS handling without changing default SDK behavior when it is left off.

## Current platform state

### Android
- primary platform for foreground-service-backed ownership while armed
- plugin-owned bridge and service wiring
- owner reporting and rehydrate support

### iOS
- honest base scaffolding exists
- readiness and diagnostics are exposed through the same public API
- background BLE ownership is still partial
