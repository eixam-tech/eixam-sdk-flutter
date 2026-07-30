# SOS lifecycle validation

This note separates automated SDK evidence from physical release evidence.
Fakes and mocks cannot prove BLE, firmware, staging backend, OS lifecycle,
signed artifacts, or store-delivered behavior.

## Current committed-head checkpoint

- SDK full suite: **665 tests passed** at
  `edbfd2328f759ee94908d8d72c201a26cd69670e`.
- App full suite: **767 tests passed** at
  `109db774977a31a2298b692af3da2673c0b683c7`.
- `packages/eixam_connect_flutter/test/sdk/sos_lifecycle_matrix_test.dart`
  covers the focused lifecycle matrix with fake repositories, device runtime,
  rehydration, and relay/backend inputs.
- `packages/eixam_connect_flutter/test/sdk/authoritative_sos_lifecycle_controller_test.dart`
  covers secure same-account restoration, lifecycle publication, terminal
  cleanup, and failure handling.
- `packages/eixam_connect_flutter/test/sdk/eixam_connect_sdk_impl_test.dart`
  contains broader orchestration, countdown, already-active, cancellation,
  device mirror, and recovery cases.
- The counts are a checkpoint for those commits, not permanent suite totals.

## Coverage boundaries

Automated cases verify SDK-first ownership; independent app/device paths;
app-only activation with device, Bluetooth, and location unavailable;
generation-scoped countdown cancellation before and after dispatch commit;
matched and unmatched already-active recovery; process restoration; pending and
failed cancellation; monotonic lifecycle/capability revisions; equal-revision
merge expectations; stale-generation rejection; device-mirrored `preConfirm`
with `packetId=0`; immediate active presentation before incident identity;
later identity enrichment; and history/external non-actionability.

These are contract tests, not a physical-completion claim.

## Physical status

Physical and backend validation against staging covered app-origin and
connected-local-device origin, stable countdown, active presentation/map,
backend and contact progress, provisional-to-canonical handoff, app/TAG
cancellation, immediate rearm, Profile sharing coexistence, privacy-safe
diagnostics, and removal of the repeated iOS Core Location main-thread
warning. The extended production-delivered matrix remains required before
production promotion. The canonical case-by-case physical matrix is maintained
in the partner app release documentation
(`docs/SOS_PHYSICAL_VALIDATION_MATRIX.md` there) to avoid two diverging release
checklists.

Physical evidence should record only lifecycle stage, capability booleans,
revision, selected path, typed blocking reason, UI outcome, and terminal
alignment. Do not retain real identities, hardware addresses, incident IDs,
coordinates, contacts, credentials, endpoints containing secrets, or raw
packets in durable documentation.

## Gap rule

Physical device-origin/relay cases pass only if existing backend, realtime,
rehydration, and firmware contracts expose sufficient authoritative active and
terminal evidence. If a live run lacks those signals, report the gap; never
promote history or stale local presentation into lifecycle proof.
