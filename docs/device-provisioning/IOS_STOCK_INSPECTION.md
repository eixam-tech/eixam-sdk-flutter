# iOS stock TAG inspection

## Scope

This change is restricted to iOS stock PhoneAPI inspection. It does not change
Android acquisition, firmware, backend configuration, the host UI contract, or
post-migration guided repair. Both SDK hosts receive the fix through the existing
inspection API; no new host state or integration is required.

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
