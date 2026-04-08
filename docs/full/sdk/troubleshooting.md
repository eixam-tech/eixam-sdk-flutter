# Troubleshooting

## `customEndpoints` rejected

Cause: `customEndpoints` were passed while using `production`, `sandbox`, or `staging`.

Fix: only pass `customEndpoints` with `EixamEnvironment.custom`.

## `initialSession.appId` mismatch

Cause: the bootstrap `appId` and the provided signed session `appId` do not match.

Fix: make both values identical.

## Bootstrap did not request permissions

Expected behavior. Permission requests remain explicit host-app actions.

## Bootstrap did not pair a device

Expected behavior. Device pairing/connection remains an explicit host-app decision.

## Protection readiness is blocked

Inspect:

- session availability
- paired/connected device state
- Bluetooth enabled state
- location permission
- notification permission
- platform capability readiness

## iOS Protection coverage remains partial

This can be expected depending on current iOS runtime ownership support.

## Realtime appears incomplete

Current realtime may still depend on backend protocol maturity. Use runtime diagnostics and current agreed backend transport behavior as the source of truth.


## Internal reminder

If behavior mismatches protocol docs, investigate whether the issue is firmware drift, stale implementation, incomplete integration, or a temporary compatibility workaround.
