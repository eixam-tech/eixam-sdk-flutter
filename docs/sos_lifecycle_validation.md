# SOS lifecycle validation

This note separates automated SDK evidence from physical release evidence.
Fakes and mocks cannot prove BLE, firmware, staging backend, OS lifecycle,
signed artifacts, or store-delivered behavior.

## Final automated status

- Flutter SDK package suite: **456/456 passed**.
- Analyzer: passed with three pre-existing `implementation_imports`
  informational notices and no warnings or errors.
- `packages/eixam_connect_flutter/test/sdk/sos_lifecycle_matrix_test.dart`
  covers the focused lifecycle matrix with fake repositories, device runtime,
  rehydration, and relay/backend inputs.
- `packages/eixam_connect_flutter/test/sdk/authoritative_sos_lifecycle_controller_test.dart`
  covers secure same-account restoration, lifecycle publication, terminal
  cleanup, and failure handling.
- `packages/eixam_connect_flutter/test/sdk/eixam_connect_sdk_impl_test.dart`
  contains broader orchestration, countdown, already-active, cancellation,
  device mirror, and recovery cases.
- Partner-app focused SOS and required supporting matrices passed. The complete
  app sweep is not claimed as passing because its pre-existing
  `login_screen_test.dart` harness hangs.
- Android staging debug/release builds and iOS staging debug `--no-codesign`
  build passed at the app integration checkpoint.

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

The user reports physically verifying the main functional paths available in
this iteration. Granular evidence is not present for every extended case, so
the full matrix remains recommended before production promotion. The canonical
case-by-case physical matrix is maintained in the partner app release
documentation (`docs/SOS_PHYSICAL_VALIDATION_MATRIX.md` there) to avoid two
diverging release checklists.

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
