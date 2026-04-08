# Android Integration

## What the SDK/plugin owns

- Protection method/event channels
- foreground-service-backed Protection runtime wiring
- merged plugin manifest pieces for the SDK-owned Android path
- runtime readiness and diagnostics exposed to Dart

## What the host app still owns

- runtime permission UX
- app bootstrap that creates the SDK instance
- app-level notification/channel branding
- any product-specific BLE or safety UX around the SDK

## Required setup

- declare Bluetooth, location and notification permissions
- keep foreground service requirements aligned with your app policy when using Protection Mode
- bootstrap with `EixamConnectSdk.bootstrap(...)`

## Important behavior

- Protection Mode is off by default
- when armed, Android is the intended strongest current path
- host UI should inspect diagnostics if readiness is blocked

## Validation checklist

1. bootstrap the SDK
2. request permissions explicitly
3. connect a device if your flow requires it
4. run `evaluateProtectionReadiness()`
5. call `enterProtectionMode()`
6. inspect `watchProtectionStatus()` and `watchProtectionDiagnostics()`
