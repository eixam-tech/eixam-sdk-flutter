# Validation And Tests

## Main Commands

Run from the repository root unless noted otherwise.

| Purpose | Command |
|---|---|
| Format check | `dart format --set-exit-if-changed .` |
| Root analysis | `flutter analyze --no-fatal-infos` |
| Root test sweep | `flutter test` |

## Package-Level Commands

| Area | Command |
|---|---|
| Core package tests | `dart test packages/eixam_connect_core/test` |
| Flutter SDK tests | `flutter test packages/eixam_connect_flutter/test` |

## High-Signal Test Files

| Area | Tests |
|---|---|
| Public SDK orchestration | `packages/eixam_connect_flutter/test/sdk/eixam_connect_sdk_impl_test.dart` |
| BLE contract surface | `packages/eixam_connect_flutter/test/sdk/eixam_connect_sdk_ble_contract_test.dart` |
| Auto reconnect | `packages/eixam_connect_flutter/test/ble_auto_reconnect_coordinator_test.dart` |
| Device runtime/provider | `packages/eixam_connect_flutter/test/device/*` |
| Core SOS / DMP state | `packages/eixam_connect_core/test/state/*`, `packages/eixam_connect_core/test/usecases/*` |

## Analyzer / Format Notes

- Root `flutter analyze --no-fatal-infos` is the repo-level baseline from the README.
- `eixam_connect_core` is a Dart package; targeted `dart test` is often the fastest check there.
- `eixam_connect_flutter` is a Flutter package; prefer `flutter test` for targeted validation.

## Manual Validation Checklist

### App-only SOS

- Verify signed session is configured.
- Verify realtime connection reaches connected state.
- Trigger SOS with no BLE device connected.
- Confirm SDK succeeds through backend path only.

### BLE SOS From App

- Pair/connect a compatible device.
- Trigger SOS from the app.
- Confirm SDK reports combined or device-available capability appropriately.
- Confirm device state converges and public incident/channel are correct.

### BLE SOS From Device

- Simulate or observe device-origin pre-confirm / active packet flow.
- Confirm public SOS state rehydrates from device status.
- Confirm backend promotion occurs when required.

### Cancel From App

- With active SOS, invoke cancel.
- Confirm one successful channel is enough for overall success.
- Confirm SOS notifications clear on terminal closure.

### Cancel From Device

- Feed or observe device-origin cancel/close path.
- Confirm SDK keeps terminal state and does not reopen PRE-SOS.

### Resolve From App

- With active SOS, invoke resolve.
- Confirm backend resolve and device convergence behave consistently.

### Background / Foreground Notifications

- Initialize local notifications through the SDK.
- Trigger device-origin PRE-SOS / SOS.
- Verify deduplication per cycle and cleanup on closure.
- If Android protection mode is in play, verify service notification and SOS background notifications.

### Relay SOS

- Feed relay-origin SOS/telemetry payloads with stable remote device identity.
- Confirm backend routing uses remote device id.
- Confirm relay `422` becomes terminal diagnostics, not infinite retry.

### DMP

- Schedule a plan with short timings.
- Confirm transitions: monitoring -> overdue -> awaitingConfirmation -> escalated -> expired.
- Verify `I'm OK` notification action path.
- Verify auto-triggered SOS when `autoTriggerSos` is true.

## Needs Verification

- Root `flutter test` is documented in the repo README, but depending on local Flutter workspace behavior you may prefer package-targeted test commands when narrowing failures. Treat package-scoped commands as the most deterministic option.
