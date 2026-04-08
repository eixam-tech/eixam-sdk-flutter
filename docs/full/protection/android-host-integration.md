# Android Host Integration

## What The SDK/Plugin Owns

- Protection method/event channels
- Foreground service class
- Merged service manifest declaration from the plugin
- Runtime snapshot persistence
- BLE ownership/readiness diagnostics exposed to Dart

## What The Host App Still Owns

- Runtime permission UX
- App bootstrap that constructs the SDK
- Validation UI consumption
- Any app-level notification/channel branding outside the plugin defaults

## Required Android Setup

- Keep Bluetooth, location, notifications, and foreground-service permissions available in the host app manifest.
- Bootstrap the SDK through `EixamConnectSdk.bootstrap(EixamBootstrapConfig(...))` before using Protection Mode.
- Do not manually register a host-side Protection bridge in `MainActivity`; the plugin now auto-registers.

## Arming Behavior

- Protection Mode is off by default.
- Full Protection behavior is only attempted after `enterProtectionMode()`.
- When armed, the plugin foreground service becomes the intended Protection runtime owner and reports `bleOwner=androidService`.
- The SDK also releases the Flutter BLE runtime from active ownership so Flutter auto-reconnect and notification subscriptions stop competing while Protection Mode is armed.
- When disarmed, ownership returns to the default Flutter path.

## Validation

1. Launch the control app.
2. Confirm normal BLE/SOS behavior still works before arming Protection Mode.
3. Open the Protection section.
4. Run readiness.
5. Enter Protection Mode.
6. Confirm:
   - foreground service is running
   - BLE owner is `androidService`
   - Flutter runtime no longer reports itself as the active owner
   - platform events are updating
   - rehydrate returns the same additive snapshot after app reattach

## Troubleshooting

- If readiness is blocked, inspect session/device pairing/permission blockers first.
- If the service starts but coverage remains partial, review `serviceBleConnected`, `serviceBleReady`, `lastBleServiceEvent`, and reconnect counters.
- If the mode is never enabled, current app behavior should remain unchanged by design.
