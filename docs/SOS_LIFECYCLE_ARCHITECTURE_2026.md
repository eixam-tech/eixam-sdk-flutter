# Authoritative SOS Lifecycle (2026)

## Decision

The Flutter SDK is the single owner of SOS lifecycle truth. Applications render
and navigate from `SosLifecycleSnapshot`; they do not reconstruct ownership
from history, timers, device summaries, routes, or preferences.

## Public model

`SosLifecycleSnapshot` exposes `idle`, `arming`, `activating`, `active`,
`cancelling`, `cancelled`, `resolved`, `activationFailed`,
`cancellationFailed`, and `recoveryRequired`. It includes the lifecycle ID and
monotonic generation, origin, actionability and display classification,
incident/device/node identity, activation and observation timestamps,
cancellation phase, recovery status, and a non-sensitive failure code.

Typed operations return `SosActivationResult` (`activated`,
`alreadyActiveRecovered`, `alreadyActiveUnmatched`, `failed`) and
`SosCancellationResult` (`cancelled`, `pendingConfirmation`,
`alreadyTerminal`, `failed`). Existing SOS methods and streams remain available
for compatibility.

```text
idle -> arming -> activating -> active -> cancelling -> cancelled/resolved
                    |             |           |
                    |             |           +-> cancellationFailed -> retry
                    |             +-> recoveryRequired -> active/cancelling
                    +-> activationFailed
                    +-> recoveryRequired (already active, proof unresolved)
terminal -> a new lifecycle ID and generation
```

## Source-of-truth rules

- Arming is accepted SDK countdown state, but is not persisted as proof.
- Active local ownership requires successful activation, a local incident, or
  an authoritative active observation from the connected/registered device.
- Backend history is never sufficient to create local actionability.
- A temporary unavailable runtime or BLE disconnect does not imply terminal
  state.
- Only an authoritative cancellation/resolution boundary clears provenance.
- Late observations older than the activation boundary, or for another node,
  cannot close the current generation.

## Secure provenance

`AuthoritativeSosLifecycleController` uses the existing
`SecureKeyValueStore`. The record is keyed as `sdk.sos.lifecycle` and contains
only: schema version, SHA-256 account scope (`appId:externalUserId`), lifecycle
ID, generation, lifecycle stage, origin, local/backend incident IDs, required
device/node identity, trigger source, activation/observation timestamps, and
pending cancellation phase.

It never stores coordinates, contacts, full incidents or payloads, BLE packets,
tokens, PSKs, voice data, or location history. A record is written only after
local ownership proof exists. Logout detaches local state and local-data/account
deletion deletes the record. A mismatched account cannot read or adopt it.
Unreadable records produce non-actionable `recoveryRequired`, never cancelled.

## Generation identity

The SDK creates `sos:<node-or-device>:<UTC-microseconds>:<monotonic-generation>`.
The timestamp plus monotonic component prevents reused firmware `packetId=0`
from merging consecutive incidents. A confirmed terminal boundary permits the
next generation; duplicate observations enrich the current generation without
creating another one.

## Activation and already-active recovery

`triggerSosAuthoritatively` publishes `activating`, invokes the existing
activation transports, and publishes/persists `active` only after proof.
`E_SOS_ALREADY_ACTIVE` is handled inside the SDK:

1. Current or persisted matching local ownership returns
   `alreadyActiveRecovered`.
2. An authoritatively active matching local device restores ownership and
   returns `alreadyActiveRecovered`.
3. Without trustworthy proof, the SDK publishes `recoveryRequired` and returns
   `alreadyActiveUnmatched`.

The unmatched case is not success and never becomes cancelled. Consumers do
not parse exception strings.

## Cancellation

`cancelSosAuthoritatively` publishes `cancelling` before invoking the existing
device/backend cancellation path. The lifecycle records `requested`,
`transportAccepted`, `deviceConfirmed`, `backendConfirmed`, or `fullyResolved`.
An existing backend-confirmed cancellation is the strongest terminal evidence
currently available and permits `cancelled` plus secure-record deletion. A
device-only acceptance remains `cancelling/pendingConfirmation` until stronger
terminal evidence arrives. Failure publishes `cancellationFailed`, retains
provenance, remains locally actionable, and permits retry. Repeated terminal
cancellation is idempotent.

## Process and BLE recovery

Initialization and session attachment restore same-account provenance before
publishing lifecycle state. An active record initially becomes
`recoveryRequired/reconciling`; a pending cancellation restores as
`cancelling`. Current incident and device observations then enrich the same
generation. BLE disconnect does not clear provenance, while reconnect can add
device evidence without duplicating the lifecycle.

## App integration contract

Applications subscribe to `sosLifecycleStream`, call
`getSosLifecycle()` for the initial snapshot, and use the typed activation and
cancellation methods. The active surface is eligible only when SDK truth is
local-actionable and not history-only. `cancelling`, `cancellationFailed`, and
`recoveryRequired` remain visible with truthful status. Only explicit SDK
`cancelled` or `resolved` closes the active surface.

## Backward compatibility and privacy

Legacy methods are retained and the SDK continues adapting device/current SOS
streams. New fields are intentionally limited to lifecycle decisions. Logs
should use reason codes and booleans; no new coordinates, hardware addresses,
user IDs, raw packets, or full incident IDs are required by this design.
