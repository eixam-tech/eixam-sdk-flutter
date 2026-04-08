# iOS Integration

## Current state

The SDK includes an iOS Protection adapter and participates in the same Dart public contract, but iOS should still be treated honestly: background BLE ownership is not as mature as Android.

## Host app expectations

- provide notification UX
- declare Bluetooth usage descriptions
- prepare `UIBackgroundModes` only when your product really needs background execution
- treat Protection Mode on iOS as capability-aware, not magically equivalent to Android

## Recommended integration rule

Use the same public bootstrap path:

```dart
final sdk = await EixamConnectSdk.bootstrap(
  const EixamBootstrapConfig(
    appId: 'partner-app',
    environment: EixamEnvironment.production,
  ),
);
```

Then request permissions and inspect readiness before arming Protection Mode.

## Troubleshooting note

If iOS reports partial coverage or degraded readiness, inspect diagnostics first instead of assuming parity with Android runtime ownership.
