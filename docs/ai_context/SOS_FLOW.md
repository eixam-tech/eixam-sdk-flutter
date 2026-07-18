# SOS Flow

## Main Sources

- SDK orchestrator: `packages/eixam_connect_flutter/lib/src/sdk/eixam_connect_sdk_impl.dart`
- Device-side state machine/origin tracking: `packages/eixam_connect_flutter/lib/src/device/device_sos_controller.dart`
- Backend-facing contract notes: `packages/eixam_connect_flutter/SOS_ORCHESTRATION.md`
- Backend repositories:
  - `data/repositories/mqtt_operational_sos_repository.dart`
  - `data/repositories/api_sos_repository.dart`

## App-Only SOS Flow

1. Host reads `getSosLifecycle()` and `getSosCapability()`, subscribes to their
   streams, and starts the SDK-owned pre-SOS countdown or typed activation.
2. The SDK publishes `arming -> activating`; legacy `SosState.sending` remains
   transport progress and is not lifecycle proof.
3. `EixamConnectSdkImpl` evaluates backend and device SOS paths independently.
4. Outcomes after authoritative acceptance:
   - backend + device available: trigger both, return `backendAndDevice`
   - backend only: trigger backend, return `backendOnly`
   - device only: trigger device, return `deviceOnly`
   - neither: fail with `E_SOS_NOT_AVAILABLE`
5. The lifecycle becomes `active` only after repository acceptance or typed
   recovery. If backend succeeds but device sync fails, activation remains
   successful and records degraded diagnostics.

A registered device, BLE, command channel, firmware runtime, telemetry,
tracking, and foreground/background location are not prerequisites for the
authenticated app/backend path. Missing device/location context removes
redundancy or enrichment only.

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
  - the SDK timer and generation-scoped dispatch token are authoritative; host
    timers only render the deadline
  - cancellation before dispatch ends the generation without backend
    cancellation; cancellation after dispatch commit follows active settlement
  - stale callbacks cannot publish into a cancelled or newer generation

## Cancel Flow

- Public `cancelSos()`:
  - publishes `cancelling` before transport work
  - best-effort closes device path when active
  - attempts backend cancellation independently, including without BLE
  - retains provenance on pending or failed cancellation
  - publishes a terminal state only after authoritative confirmation
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

- `canActivateSos = canTriggerAppSos || canTriggerDeviceSos`
- Host apps must not decide channel routing themselves.
- Capability and delivery are different:
  - capability = what can be used now
  - delivery = what was actually used for the active/last public SOS
- Device SOS availability is based on a live SOS command path, not only generic readiness.
- One successful channel is enough for public success.
- Relay-origin `422` backend rejections are terminal for that publish attempt.
- Lifecycle and capability revisions are monotonic. Equal-revision halves merge
  in either arrival order; older snapshots are rejected.
- Current-active matching for already-active recovery is bounded and SDK-owned.
  Backend history never establishes local actionability.
- `packetId=0` is not lifecycle identity. App-origin device `preConfirm` mirrors
  and enriches the same generation, while authoritative active state prevents
  countdown resurrection.

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

## Integration source of truth

See [`../SOS_LIFECYCLE_ARCHITECTURE_2026.md`](../SOS_LIFECYCLE_ARCHITECTURE_2026.md)
for the complete lifecycle, secure provenance, recovery, cancellation, and
revision contract. Preserve current typed behavior when older legacy-state
documentation differs.
