# iOS stock TAG inspection

## Scope

These changes cover iOS stock PhoneAPI inspection and verified post-installation
handoff to existing guided Bluetooth repair. It does not change
Android acquisition, firmware, backend configuration, the host UI contract, or
the guided repair UI and its strict runtime verification. Both SDK hosts receive the fix through the existing
inspection API; no new host state or integration is required.

## Connected stock discovery

The fresh product run with SDK `d156667` passed two direct inspections but QR
discovery reported not found. A read-only iOS system-connected snapshot returned
the same peripheral handle, `Meshtastic_756e`, via the stock PhoneAPI service,
with an empty advertised name. The SDK had considered advertisements only.

iOS discovery now appends system-connected stock candidates with normal
`Meshtastic_` plus four-hex-digit names. Existing fresh advertisements win,
current Eixam-service connections are excluded, and these candidates receive no
fabricated MAC or advertising identity. The usual protected model/MAC inspection
must still establish the full QR match. This performs no device connection or
write. Android never executes this query. System-query failure preserves normal
advertisements, and cancellation generations still discard late results.

## Failure evidence

On 2026-10-28, stock `2.7.26.54e0d8d` on QR `N693756E` connected successfully
through official Meshtastic iOS after a normal software reboot. Eixam subsequently
completed protected access and notifications. The first inspection returned
metadata, while migration's immediate revalidation timed out at
`waitingForMetadata` after eight seconds. Cleanup then cancelled the connection.
This was not the earlier USB-induced rejection callback failure.

Stock nRF52 `onToRadioWrite` remembers `lastToRadio` and drops identical
consecutive writes. Its GAP disconnect callback clears that buffer. The SDK's
repeated config-only nonce 69420 generates identical request bytes. If another
iOS client retains the physical connection while this manager disconnects, the
buffer can survive this logical release. A read-only physical probe against
published SDK `4756371` at 11:11:46 UTC reproduced the failure: the TAG logged
`Drop dup ToRadio packet we just saw`, then sent the abandoned file-manifest
tail and config-complete response. The SDK returned `malformedMetadata`.
This proves repeated request rejection in the retained-link state. The official
Meshtastic process was still running after a normal termination signal;
process presence alone does not attribute every physical connection owner.

## SDK behavior

iOS allocates a nonzero per-inspection uint32 config nonce, excluding Meshtastic's
special config-only and node-only values. The request remains read-only. Security
is still established by awaiting a protected read before notification setup.
Frames received before the fresh request are ignored. Completion requires the
hardware model, own node number, and MAC belonging to that same node. A matching
config-complete response without this evidence remains a typed verification
failure. Cleanup and cancellation retain the existing connection-owner boundary.

Android continues sending the existing config-only nonce and retains its existing
completion rules. No consumer reboot state or App workaround is introduced.

## Validation

Focused regressions distinguish a retained physical connection from a GAP
disconnect that resets stock's duplicate buffer. They also cover metadata
arriving before identity, another node's MAC, unsolicited
pre-request metadata, incomplete identity, and unchanged Android request bytes.
Existing migration tests retain model 105, exact QR correlation, wrong-target
rejection, no-DFU-before-verification, guided repair and restart coverage.

The initial focused suite passed 224 tests, including native Swift connection
preparation checks; 161 provisioning/assignment/firmware tests and two core QR
tests also passed. The corrected physical/logical-disconnect model passed 43
inspection/codec tests. Analysis of changed files passed. Root analysis is affected by
pre-existing generated QA scripts under ignored `build/` with unresolved imports;
the detailed log is retained outside the repository. Physical verification must
still be recorded separately; unit tests do not prove Ready or provisioning.

## Verified installation with a cached stock service table

The physical flow completed protected inspection and revalidation, then one
approved catalog DFU to version `2.7.68`. A read-only standard Device Information
Service read on that same iOS peripheral returned `2.7.68.f9a277c`, while iOS
still exposed the stock service table. Compatibility-first migration verification
had rejected the connection before reading this installation evidence.

Only on iOS, migration verification may read DIS despite missing Eixam runtime
services. Entering the existing `bluetoothRepairRequired` state requires the
exact captured peripheral, the inspected model-105 hardware MAC, a matching
installed target version, and the authoritative migration-owned firmware session
with artifact verification and native transfer engagement. Release, target
version and hardware identity must agree. This also handles a retained stock name
after process restart. Firmware completion records installation only; runtime
readiness still requires the existing guided repair checks, notifications and
normal provisioning. Android compatibility gates are unchanged. This path never
starts another transfer or changes bonds.

Migration, session-store and firmware-coordinator regression suites passed 221
tests, including iOS/Android, existing/scanned connections, cached stock names,
missing transfer proof, version mismatch and failed DIS reads. Changed-file
analysis passed. Restart fixtures reuse a fake canonical firmware service and do
not establish atomic crash recovery between firmware completion and durable
migration-state publication. Physical guided repair/provisioning remain separate
acceptance requirements.

## iOS fresh provisioning connection observations

An explicitly authorized target-only unprovision exposed a separate fresh
provisioning failure after GATT recovery. The normal App read unprovisioned
state, fetched configuration and sent all 20 SoftSIM chunks, then COMMIT
admission reported `epochValid=false cancelled=false` with typed
`connectionEpochInvalid`. A subsequent trace showed a raw disconnected status,
followed by repository `runtime_status` connected=true with `emit_skipped`; the
ACK listener never received that connected transition.

iOS provisioning now observes the existing seeded SDK public device-status
stream, which also publishes authoritative explicit refresh/active-owner status.
Its writes already use the active owner. Android retains the raw repository
stream. The ACK coordinator and its uncertainty safeguards are unchanged: a
connected-only sample after an ACK timeout cannot reset the poisoned epoch.
Functional regressions reproduce the raw disconnected/silent-connected-refresh
gap through the real SDK stream and transfer all 20 chunks plus COMMIT only
with authoritative status. The focused provisioning/stream/assignment suite
passed 110 tests before immutable physical validation.

## Provisioning-reboot recovery lifetime and RC upgrade

The physical fresh transfer eventually admitted COMMIT, applied radio settings
and rebooted. Reconnection then failed with a stale GATT handle: provisioning
changes stock-service availability, so the existing iOS repair can also be
needed at this reboot. The host had retired migration proof at paired handoff.

The SDK now retires completed iOS migration proof only after matching runtime
Ready plus explicit current-account assignment readback. The App releases its
acquisition presentation guard after exact-target paired handoff while retaining
SDK recovery authority; entering repair reacquires the presentation guard.
Android handoff and provisioning behavior remain unchanged.

For upgrades from an RC that already retired proof, the SDK can read its own
canonical retired records. Only one completed inspected model-105/MAC record
with matching exact peripheral, firmware release/version/hardware and verified
native transfer evidence is eligible. Conflicting runtime MAC or advertised
identity, ambiguity, malformed history, generic errors and missing connections
are rejected. An actual iOS stale-GATT error and a fresh matching DIS read are
required before publishing the existing repair state. A session revision and
ownership check prevents delayed reads from replacing newer work. No fixture
injection, new recovery enum, transfer, unprovision or firmware write occurs.

254 SDK migration/store/provisioning/assignment tests passed, including archive
identity/ambiguity/ownership rejection and Ready-with-unverified-assignment
retention. The original retained-proof inter-store crash gap remains outside
this claim; canonical completed archive recovery is independently guarded.
