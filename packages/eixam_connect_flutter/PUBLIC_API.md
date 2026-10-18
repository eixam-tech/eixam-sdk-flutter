# Public API Notes

This guide is intentionally integration-oriented.

It explains what partner apps should call and observe for relay ingest without
moving protocol or orchestration responsibilities out of the SDK.

## Minimal Host Responsibilities

Partner apps are expected to:

- bootstrap the SDK with the correct `appId` and environment
- set or refresh the signed SDK session
- explicitly connect a compatible BLE device when device-backed features are needed
- read initial `SosLifecycleSnapshot` and `SosCapabilitySnapshot`, subscribe to
  both streams, and render typed lifecycle/capability state
- optionally expose diagnostics to support or QA users

Partner apps are not expected to:

- decode relay TEL or SOS packets

- map relay BLE payloads to backend device ids
- reconstruct SOS lifecycle from history, legacy transport progress, timers, or
  device summaries
- parse `E_SOS_ALREADY_ACTIVE`, select activation transports, or optimistically
  cancel

Those responsibilities stay inside the SDK/runtime layers.

## Connected-device live position batches

`watchResolvedLocation()` remains the latest/current resolved-position stream.
For a connected TAG `0xD3` live batch, only the newest sample updates that
current marker.

`watchDevicePositionBatches()` emits one `EixamDevicePositionBatch` per valid
firmware `0xD3` message. Each batch contains 1–24 real TAG samples in firmware
order (oldest to newest); the SDK does not fabricate or deduplicate samples.
`receivedAt` is phone/SDK reception time, while each sample's nullable
`sampledAt` is the TAG time. `timestampValid` is true only when that TAG Unix
time is within seven days before or ten minutes after reception. This is a
live-transport plausibility safeguard, not proof of RTC synchronization.

Each sample has an opaque SHA-256 `stableSampleKey` over its canonical 16-byte
firmware record for application idempotency. For undated records, replay
identity is necessarily limited to the identity present in those record bytes.
The source is always `SdkLocationSource.connectedDevice`. Classic 12-byte TEL
continues to update current location and does not emit a synthetic batch.

The SDK does not yet expose the firmware `0xD1` persistent-backlog protocol.
Actual live batch density depends on firmware sampling and scheduling; consumers
must use the samples received and must not infer missing intermediate points.

## Relay Ingest

When BLE relay payloads include a stable remote device identity:

- relay telemetry is published using that remote backend `deviceId`
- relay SOS is published using that remote backend `deviceId`
- the gateway/local BLE device remains diagnostics context only

Current public relay visibility:

- `SdkOperationalDiagnostics.lastTelRelayRx`
- `SdkOperationalDiagnostics.bridge`

The bridge diagnostics fields most useful to integrators are:

- `lastRelayRemoteDeviceId`
- `lastRelayTelemetryPublishAttempt`
- `lastRelayTelemetryPublishResult`
- `lastRelaySosPublishAttempt`
- `lastRelaySosPublishResult`
- `lastRelayTerminalErrorCode`
- `lastRelayTerminalErrorMessage`

## Relay `422` Terminal Behavior

For relay-origin ingest only, the SDK treats backend `422`/unprocessable-style
responses as terminal for that publish attempt.

This means:

- the SDK records terminal relay diagnostics
- the SDK does not keep retrying that same relay publish as a transient pending item
- host apps should not add app-side retry logic for the same relay payload

## Diagnostics vs State

Use public APIs this way:

- use `SdkOperationalDiagnostics` for relay/bridge/support diagnostics
- use `SosIncident.deliveryChannel` and SOS capability fields for public SOS UX

Diagnostics are descriptive and support-oriented. They should not replace the
SDK’s typed public state for host control flow.

## SOS lifecycle and capability

Use `getSosLifecycle()` plus `sosLifecycleStream` and `getSosCapability()` plus
the capability stream for the initial and ongoing contract. Lifecycle owns
idle through terminal/failure/recovery states; capability independently reports
whether app/backend or connected-device activation and current cancellation are
available.

App/backend activation does not require a registered device, BLE, command
channel, firmware runtime, telemetry, tracking, or a location fix. The SDK owns
transport selection, countdown and dispatch ordering, bounded already-active
recovery, cancellation confirmation, account-scoped persistence, and revision
ordering. Host consumers merge equal revisions and reject stale ones.

See [SOS orchestration](SOS_ORCHESTRATION.md) and the repository
[authoritative lifecycle architecture](../../docs/SOS_LIFECYCLE_ARCHITECTURE_2026.md).

## Nearby LoRa text

`sendNearbyBroadcastText(String)` writes UTF-8 to the connected TAG. The TAG
broadcasts on mesh port 262 (hop 0, PRIMARY PSK). `sendNearbyDirectText` is a
PKI 1:1 (needs dest public key already on the TAG). `sendNearbyGroupText`
uses a SECONDARY PSK installed with `setNearbyGroup` — never a PRIMARY swap.
`NearbyGroupCommandResult.slotsFull` is REJECT detail `0xFF` (7 SECONDARY slots).
`setNearbyGroup(..., replace: true)` wipes tag groups when full (action 2).
`setNearbyGroup` retries once on ACK timeout while the TAG stays connected.
`badKey` is `0xFE`, `persistFailed` is `0xFD`, `sosBlocked` is `0x01`.
`watchNearbyText()` emits incoming messages with dest / groupId / pki flag.
`watchNearbyTextTxStatus()` emits every `0xDA`, including later delivery ACKs
(`meshAck` / `recipientAck` / `ackTimeout` / `gotNak`) for a packet already
returned by send. Correlate by `packetId`. Firmware ≥ **2.7.63**. PKI DMs set
`want_ack`; plaza/group stay hop 0 and get an explicit hop-0 ROUTING ACK from
a nearby receiver (SNR-staggered; later nodes cancel if they overhear one).
`watchNearbyNodeNames()` emits NodeInfo `long_name` heard by the connected TAG
(`0xDB`). That is the display name of the phone currently on that TAG, or
`EIXAM_<nodeId>` when nobody is connected. `setNearbyOwnerDisplayName` pushes
this phone's profile name onto the TAG (`0x42`, 1–39 UTF-8 bytes). Empty names
are ignored. Cached and resent on the next connect. Old firmware that ignores
`0x42` still advertises `EIXAM_<nodeId>`.

Text caps: 231 B UTF-8 for plaza and group (`tooLong` above that; the mesh
`Data` protobuf costs 8 B and 233 B would not fit the LoRa frame), 200 B for
PKI DMs.

Hosts persist messages. The SDK does not. There is no cellular fallback.
`NearbyTextTxStatus.timeout` means the TAG never answered `0xDA`.
Native protection keeps the GATT link in background and still carries Nearby:
writes go through the native command owner, and TEL notifies are forwarded to
Dart (`telNotifyReceived`). Hosts should not treat protection as a Nearby lock.
Firmware ≥ **2.7.56** is required; 2.7.55 plaza-only framing is not compatible.
Firmware ≥ **2.7.57** enforces the 231 B cap and ignores SECONDARY group keys
on TEL/SOS/cluster ports. Firmware ≥ **2.7.58** for owner-name `0x42` / `0xDB`.

## Firmware recovery contract

Firmware and migration sessions are SDK-owned. Hosts render `nextAction` and
call the SDK reconciliation/recovery APIs; they do not infer recovery from BLE
absence or platform error messages. `waitForDevice` preserves an uncertain or
temporarily unavailable device. `recover` and `retryRemoteRecovery` identify a
supported remote opportunity. `physicalRecovery` / `physicalRecoveryRequired`
represent the manual recovery verdict.

For an interrupted transfer, manual recovery requires durable evidence that
native transfer engaged, the correct supported recovery endpoint was strongly
matched, a native remote recovery invocation actually ran and failed terminally,
bounded recovery opportunities were exhausted, and the expected application
did not return. GATT 133 is a transport failure; it is not proof of invalid
firmware. Absence without that evidence remains waiting. An independent
authoritative platform verdict for the same device can also establish that an
invalid application has no supported remote recovery capability.

The coordinator permits at most three native remote recovery invocations. It
fully releases each failed invocation before reconciling/retrying. If the
matched recovery endpoint disappears after a terminal failure, three fresh
reconciliation scans exhaust the current remote opportunities. Android Nordic
DFU 2.11 additionally retries the initial GATT connection three times
(initial connection plus two retries); its configured DFU disconnect retry
limit is three. Exhaustion survives process death and prevents endless retries.

After physical recovery, the SDK verifies the same hardware and actual
application/version. A returned target completes only after verification; a
valid old application returns a safe transfer retry; a recovered stock source
returns `continueMigration`. A different hardware identity cannot complete the
session. Hosts keep showing the SDK-directed journey until that verdict changes.

After native completion, temporary Bluetooth/rediscovery errors stay in bounded
installed-version verification. They do not turn a completed transfer into a
failed native operation. If the normal runtime reconnects first, migration
verifies the captured device identity, Eixam GATT capability, and installed
version through that connection without disconnecting its owner or requiring
an advertisement. Unavailable scans do not count as missing recovery evidence.

Firmware information, release eligibility, and reconciliation request a fresh
installed-version inspection from the connected runtime. A missing or failed
inspection cannot confirm the target using a cached version. A disconnected
snapshot remains waiting until the actual application can be verified.

## Optional logical activity sessions

Production SDK instances implement `ActivitySessionControl`. Detect support with
`sdk is ActivitySessionControl`; the base `EixamConnectSdk` interface has no new
required members. The public model is named `SdkActivitySession` to avoid a source
collision with host applications' existing activity models.

```dart
if (sdk is ActivitySessionControl) {
  final session = await sdk.startActivitySession(
    activityKey: 'org.example.paddling',
  );
  // Render sdk.watchActiveActivitySession(): SdkActivitySession or null.
  await sdk.endActivitySession(sessionId: session.sessionId);
}
```

A session is logical context. Starting, restoring, or ending it does not request
permissions, start/stop GPS, acquire native location ownership, or change SOS or
DMP. Continuous tracking is a separate capability. Activity catalogs, allowed
activities, default/selected activity, and partner context belong to the host;
a default never starts a session.

Keys are extensible strings: 1–64 ASCII characters matching
`^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$`. Unknown keys are accepted; uppercase and
whitespace are rejected without normalization. Examples: `mountain`,
`trail_running`, `via-ferrata`, `org.example.paddling`.

`getActiveActivitySession()` returns the active session or null.
`watchActiveActivitySession()` seeds that state and emits ordered, persisted
changes. A successful end emits null; ended records are never exposed. A failed
initial restoration emits an error and closes that subscription; retry the read
or subscribe again after resolving storage availability.

Only one session can be active. Repeating start with its key returns the same
session without another transition. Another key produces `E_ACTIVITY_CONFLICT`;
end the matching session explicitly before starting another. End with the current
ID persists a private ended tombstone. Repeating that end succeeds, including
after restart. A different stored ID conflicts. End against absent storage is a
safe no-op. Starting after an end creates a new ID, even for the same key.

SDK-produced `startedAt` is UTC, sampled when the serialized start is accepted
for persistence. Publication waits for verified persistence; the timestamp is
not the later acknowledgement time. It remains unchanged on retries and restart.

Commands require an authenticated SDK identity (`E_SDK_SESSION_REQUIRED`). Storage
is scoped by installation, backend URL (trailing slashes ignored), `appId`, and
`externalUserId`; canonical SDK identity enrichment and signing-hash rotation do
not create another identity. Different established SDK user IDs invalidate the
record. Logout, account replacement, and local account-data deletion clear the
activity under its writer lease. Without a restored authenticated identity,
orphan data is discarded before a fresh login. Disposal preserves the session.

Persistence uses one versioned record, UTC timestamps, and verified backend
readback before publishing a transition. Corrupt/unsupported matching records
are preserved and produce `E_ACTIVITY_RESTORE_FAILED`; they are never silently
treated as absent. Explicit account-data cleanup can remove them. Rejected or
thrown writes are reconciled against storage: confirmed intended content permits
success, otherwise `E_ACTIVITY_PERSISTENCE_FAILED` leaves mutations gated by a
fresh successful reload. Cleanup failures remain gated until verified cleanup
succeeds; observers receive an error instead of an unconfirmed empty state.
No credentials, GPS history, partner configuration, or emergency
content are stored. SharedPreferences is not a transactional database or a
power-loss durability guarantee.

`ActivitySessionException implements Exception` exposes stable `code` and
`message` fields. Catch it explicitly; it intentionally does not expand the
sealed `EixamSdkException` hierarchy. Codes are `E_ACTIVITY_INVALID_KEY`,
`E_ACTIVITY_CONFLICT`, `E_ACTIVITY_PERSISTENCE_FAILED`,
`E_ACTIVITY_RESTORE_FAILED`, and `E_ACTIVITY_UNAVAILABLE`.

The supported writer boundary is one live activity controller per physical
SharedPreferences namespace in one Dart isolate. A second SDK can bootstrap,
but accessing its activity capability returns `E_ACTIVITY_UNAVAILABLE` while
another controller owns the lease. Disposal releases it. Identity replacement
also rejects stale commands with that code. Cross-isolate/process activity
writers and automatic activity-owned tracking are unsupported.


## Remote activity availability (optional)

Detect `sdk is ActivityAvailabilityControl` before using this additive capability.
It reads the authenticated app's assignment from `GET /v1/sdk/activities`:
`{"activities":[{"id":"6f1c2a3e-8b4d-4c1e-9f2a-1b3c4d5e6f70","key":"mountain"}]}`.
Results are immutable complete snapshots in backend array order; duplicate rows
are preserved. `id` is the stable backend UUID; `key` is preserved exactly.

```dart
if (sdk is ActivityAvailabilityControl) {
  final availability = sdk as ActivityAvailabilityControl;
  final cached = await availability.getCachedActivityAvailability(); // no HTTP
  final subscription = availability.watchActivityAvailability().listen(
    (snapshot) { /* render a snapshot or an invalidation */ },
    onError: (Object error) { /* report cache/refresh failure */ },
  ); // seeds cached/current state; never fetches
  final fresh = await availability.refreshActivityAvailability();
  // Cancel subscription when the host no longer needs it.
}
```

`null` means no usable snapshot. A non-null snapshot with `activities.isEmpty`
is an authoritative empty assignment, persisted like any successful response.
`fetchedAt` is SDK UTC metadata; `fromCache` is true for cache getters and watch
seeds/restoration, false for a successful refresh and its live publication.
Cached data may be stale indefinitely: M2B has no TTL, polling, push, or implicit
fetch. The host chooses explicit refresh triggers. Same-identity concurrent
refreshes coalesce. Temporary network/server/rate-limit/invalid-response failures
report errors and retain last-known-good data; they never become empty results.

Cache writes require read-back confirmation before publication. Corrupt,
unreadable, or unsupported cache raises `ActivityAvailabilityException` with
`E_ACTIVITY_AVAILABILITY_RESTORE_FAILED`; it is never treated as empty. Explicit
refresh can replace it. Local write/cleanup failures use
`E_ACTIVITY_AVAILABILITY_PERSISTENCE_FAILED`. Transport failures retain existing
`NetworkException` behavior (429 uses `E_ACTIVITY_AVAILABILITY_RATE_LIMITED`);
401 uses `AuthException` and invalidates the snapshot and cache. If that cleanup
cannot be confirmed, persistence failure takes precedence and cache access stays
blocked until checked cleanup succeeds. Errors are also delivered to observers.

The versioned private cache distinguishes backend URL (ignoring trailing slashes),
app ID, and external user ID, and checks canonical SDK user ID when available.
Signing-hash rotation and canonical enrichment preserve the logical principal.
Production transports have fixed endpoints: bootstrap a new SDK instance when
changing backends. A mismatched reinitialization fails availability refresh closed
without sending a request to the old backend.
Identity changes immediately fence old observations/results; account changes and
local-user wipe/logout clear checked storage. Invalidation emits `null`, which
does not claim successful disk deletion. Failed deletion blocks cache adoption.
Disposed/obsolete work cannot publish; an already-started disk write is drained
and reconciled away before a new identity reads. Arbitration covers SDK runtimes
in the same isolate, as for ActivitySession; cross-isolate writers are unsupported.

Availability has no selected/default activity, partner, branding, UI/catalog, or
host-support semantics. It neither starts nor ends ActivitySession, tracking, SOS,
or DMP. Session operations never consult availability. Backend keys follow
`[a-z0-9_-]{1,50}`, which differs from the frozen ActivitySession grammar. Hosts
must only start sessions for keys compatible with their implemented activity/session
contract. The commercial app will later intersect remote keys with its local
ActivityCatalog; M2B does not perform that intersection, alias, normalize, or drop
keys because ActivitySession would reject them.
