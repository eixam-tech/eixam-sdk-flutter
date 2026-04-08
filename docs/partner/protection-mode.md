# Protection Mode

Protection Mode is an additive runtime capability that arms a higher-resilience path for critical BLE and SOS handling without changing default SDK behavior when it stays off.

## What the partner should know

- Protection Mode is off by default
- the host app must arm it explicitly
- readiness can be evaluated before arming
- Android has the most complete current path
- iOS participates honestly but may remain partial depending on runtime ownership support

## Recommended flow

```dart
final readiness = await sdk.evaluateProtectionReadiness();

if (readiness.canEnterProtectionMode) {
  await sdk.enterProtectionMode();
}
```

## Primary methods

- `evaluateProtectionReadiness()`
- `enterProtectionMode(...)`
- `exitProtectionMode()`
- `getProtectionStatus()`
- `watchProtectionStatus()`
- `getProtectionDiagnostics()`
- `watchProtectionDiagnostics()`
- `rehydrateProtectionState()`
- `flushProtectionQueues()`

## Host responsibilities

- declare native permissions and capabilities
- own permission education UX
- decide when to arm/disarm the mode
- render status/diagnostics meaningfully

## Platform note

For deeper platform details, see [Android Integration](android-integration.md) and [iOS Integration](ios-integration.md).
