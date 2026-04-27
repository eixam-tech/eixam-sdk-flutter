# SOS Flow

## Main Sources

- SDK orchestrator: `packages/eixam_connect_flutter/lib/src/sdk/eixam_connect_sdk_impl.dart`
- Device-side state machine/origin tracking: `packages/eixam_connect_flutter/lib/src/device/device_sos_controller.dart`
- Backend-facing contract notes: `packages/eixam_connect_flutter/SOS_ORCHESTRATION.md`
- Backend repositories:
  - `data/repositories/mqtt_operational_sos_repository.dart`
  - `data/repositories/api_sos_repository.dart`

## App-Only SOS Flow

1. Host calls `sdk.triggerSos(...)`.
2. `EixamConnectSdkImpl` evaluates backend availability and device SOS availability.
3. Outcomes:
   - backend + device available: trigger both, return `backendAndDevice`
   - backend only: trigger backend, return `backendOnly`
   - device only: trigger device, return `deviceOnly`
   - neither: fail with `E_SOS_NOT_AVAILABLE`
4. If backend succeeds but device sync fails, overall public trigger still succeeds and records diagnostics.

## BLE / Device-Origin SOS Flow

1. BLE runtime decodes SOS packets/events.
2. `DeviceSosController` updates `DeviceSosStatus`.
3. `EixamConnectSdkImpl` distinguishes:
   - app-origin / correlated app-triggered status
   - device-origin status
4. For device-origin status, the SDK may synchronize backend lifecycle via `_synchronizeDeviceOriginatedBackendLifecycle(...)`.
5. Notifications are only emitted for device-origin notifiable states from BLE packets or device timeout promotion.

## Pre-SOS / Countdown Flow

- Public PRE-SOS state is exposed as `SosState.arming`.
- Main handling lives in:
  - `confirmPreSos(...)`
  - `_syncPreSosSession(...)`
  - `_handlePreSosTimerTick()`
  - `_rehydrateDeviceSosPublicState(...)`
- Important behavior:
  - app-origin pre-confirm can auto-promote to public SOS when countdown expires
  - device-origin pre-confirm is exposed publicly as arming
  - if a device-origin countdown expires, the local PRE-SOS session is cleared rather than auto-confirmed from the app path

## Cancel Flow

- Public `cancelSos()`:
  - remembers closure intent
  - best-effort closes device path when active
  - attempts backend cancel when available
  - succeeds if one valid channel succeeds
- Device closure uses `_closeDeviceSos(intent: cancel, ...)`.
- If the cycle closes, SDK clears SOS notifications and resets cycle suppression state.

## Resolve Flow

- Public `resolveSos()` mirrors cancel orchestration.
- Backend resolve uses repository support.
- Device convergence currently uses the existing device close path, not a distinct public device-resolve command.

## Backend-Triggered / Backend-Synced Behavior

- Backend-origin lifecycle updates can arrive through realtime events.
- `MqttOperationalSosRepository` listens to `RealtimeEvent` and updates the active incident when IDs match.
- Device-origin or relay-origin events may also be promoted to backend through the BLE operational bridge and SDK orchestration.

## Terminal States

- Public SOS terminal states:
  - `cancelled`
  - `resolved`
  - `idle` after no active backend incident / no device fallback
- Device SOS terminal states:
  - `inactive`
  - `resolved`

## Known Invariants

- `canActivateSos = backendSosAvailable || deviceSosAvailable`
- Host apps must not decide channel routing themselves.
- Capability and delivery are different:
  - capability = what can be used now
  - delivery = what was actually used for the active/last public SOS
- Device SOS availability is based on a live SOS command path, not only generic readiness.
- One successful channel is enough for public success.
- Relay-origin `422` backend rejections are terminal for that publish attempt.

## Main Files

- `packages/eixam_connect_flutter/lib/src/sdk/eixam_connect_sdk_impl.dart`
- `packages/eixam_connect_flutter/lib/src/device/device_sos_controller.dart`
- `packages/eixam_connect_flutter/lib/src/data/repositories/mqtt_operational_sos_repository.dart`
- `packages/eixam_connect_flutter/lib/src/data/repositories/api_sos_repository.dart`
- `packages/eixam_connect_core/lib/src/state/sos_state_machine.dart`
- `packages/eixam_connect_core/lib/src/entities/public_pre_sos_status.dart`

## Related Tests

- `packages/eixam_connect_core/test/state/sos_state_machine_test.dart`
- `packages/eixam_connect_core/test/usecases/trigger_sos_use_case_test.dart`
- `packages/eixam_connect_core/test/usecases/cancel_sos_use_case_test.dart`
- `packages/eixam_connect_core/test/usecases/get_sos_state_use_case_test.dart`
- `packages/eixam_connect_flutter/test/device_sos_controller_test.dart`
- `packages/eixam_connect_flutter/test/sdk/eixam_connect_sdk_impl_test.dart`
- `packages/eixam_connect_flutter/test/sdk/eixam_connect_sdk_ble_contract_test.dart`

## Needs Verification

- There is strong coverage for public PRE-SOS behavior, but there is no separate top-level design doc that fully defines all UI expectations for every pre-confirm edge case. Prefer preserving existing behavior from tests and `EixamConnectSdkImpl`.
