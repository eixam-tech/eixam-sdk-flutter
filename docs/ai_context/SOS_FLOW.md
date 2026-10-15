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

A physical `0xE1` user cancellation from a newer generation must never be
consumed as an older remote-terminal clear acknowledgement, even if the TAG
reuses its packet counter/cycle key. It proceeds through the current generation's
pending-activation cancellation path. Late `0xE2`/`0xE3` command acknowledgements
remain cleanup evidence for their captured operation and do not cancel a newer
generation. Android B3 reproduced the failure after WEB CANCEL, explicit rearm,
APP countdown cancellation, and a second rearm: the old clear proof previously
swallowed the new physical cancel and left countdown/backend handoff alive.

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

## Admission after a mirrored terminal generation

A BLE SOS packet's `packetId` is a transmission counter, not an episode ID.
The deployed firmware increments it in `sendSOSPacket()` for every absolute,
delta or minimal transmission. Changed counters and unconsumed fingerprints
cannot reopen a mirrored terminal generation while physical closure is missing.
Shared physical-start admission requires current-domain terminal receive evidence
before accepting the next physical edge in that case. Explicit public APP
activation remains an independent new-generation path.

`SOS_ARM_CALL_SITE` records the actual allocation caller and before/after
generation at `beginArming`, including rejected and joined requests.
`SOS_PHYSICAL_START_ADMISSION` records the receive producer, protocol counter,
retry count and correlation. `SOS_BACKEND_CREATE_CALL_SITE` records the local
dispatch generation/attempt before the repository call. Standard diagnostic
redaction still applies; QA records the diagnostic event time and correlates
typed public lifecycle/incident identities separately. The public activation
API carries no user-intent token; diagnostics must not invent one or infer a
human caller from lifecycle origin.

## Terminal propagation to a CoreBluetooth peripheral

A connected iOS peripheral UUID is a transport handle and must not be stored
as a canonical MAC. The same selected-peripheral plus hydrated own-node proof
used by command readiness also authorizes a current-cycle terminal target when
no canonical hardware address is available. Canonical MAC matching remains
unchanged when an address exists.

Remote RESOLVE captures an immutable account/lifecycle/generation/incident and
TAG target, sends `SOS_ACK` (`0x07`) on EA04 through the authorized writer, and
waits for physical E3 terminal evidence. A not-ready writer preserves the
current target and queued terminal operation until an authorized writer can
deliver it. Revalidation rejects another peripheral or TAG node and an obsolete
lifecycle before dispatch or ACK consumption. Backend/UI terminal state alone
is not a physical TAG ACK. WEB ACK remains the separate nonterminal silence
operation. This target rule does not change SOS start admission or terminal
generation watermarks.

The iOS native snapshot parser accepts the six-byte `E3` event on SOS and TEL,
persists its kind as `resolved`, and forwards the original bytes through
`ownDeviceSosLifecycleObserved`. It must not classify `E3` as user cancellation.
The persisted resolved kind prevents replay of the preceding active snapshot;
the Dart snapshot merge leaves logical authority with the backend lifecycle and
requires the real native receive event for physical terminal acknowledgement.

An SDK-guarded RESOLVE target can retain a physically observed `preConfirm`
mirror after native rehydration while its authoritative generation is already
active/terminal. `DeviceSosController` retains that correlation just as target
capture does; a current operation, matching node and exact physical E3 receive
evidence are still required. An unguarded, wrong-node or uncorrelated E3 cannot
close a countdown. This changes no backend authority, start admission, LoRa
return routing, wire command or generation fence.

## ACK silence through command ownership handoff

WEB ACK sends nonterminal `SOS SILENCE` (`0x09`) on EA04 and waits for its
`E9` command result. An admitted own-TAG ACTIVE observation captures its
account, lifecycle/generation, node, and physical connection identity. A
transport-only `DeviceSosController.detach()` may reset the live mirror but
does not discard that physical proof or a correlated pending ACK intent.
Writer readiness retries the intent without requiring another SOS packet.
Each write, including native fallback, revalidates the current lifecycle and
target. Physical closure, session changes, another generation, or another TAG
invalidate the proof. CoreBluetooth targets retain their selected UUID and
hydrated own-node binding; UUIDs are never canonical MACs. Duplicate ACKs share
one operation. Silence leaves SOS ACTIVE and configured volume unchanged;
RESOLVE remains the separate `0x07`/E3 terminal operation.

## Physical evidence during explicit rearm

`DeviceSosController` respects shared physical-start admission: `sameCycle`
evidence preserves the current countdown and app origin, then confirms ACTIVE.
An old E3/E1 receive boundary and a later receive sequence do not authorize
another countdown once the shared lifecycle has already admitted the next
generation. The standalone fallback only consumes that edge from a closed
device state. Terminal watermarks and terminal command propagation are unchanged.

## Physical cancellation at the APP dispatch boundary

A confirmed own-TAG `0xE1` invalidates a matching pending APP activation before
asynchronous repository lookup or handoff processing. Confirmation continuations
retain their pending generation and revalidate it after lookup, device status,
position loading and repository completion. `confirmPreSos` cannot implicitly
arm a terminal generation; a new explicit arm remains valid immediately after
terminal settlement.

The dispatch commit is recorded immediately before the repository create call,
after the generation claim and its awaited persistence. A cancellation before
that boundary prevents creation. If creation is already in flight, cancellation
waits for that same operation and closes its incident even if BLE has already
published ACTIVE. Its completion cannot publish ACTIVE or manufacture another
generation. `SOS CONFIRM` (`0x05`) has no wire cycle ID, so the SDK checks the
captured generation again before writer dispatch and native fallback. Retries,
B1 transport-only handoff rules, and B2 `0x07`/E3 terminal propagation remain
enabled.
