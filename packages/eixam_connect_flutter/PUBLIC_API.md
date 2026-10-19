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

`watchDevicePositionBatches()` emits novel connected-TAG positions from live
delivery and persistent backlog recovery. Firmware `0xD3` messages contain 1–24
real samples in firmware order (oldest to newest). The SDK removes recognized
replays using bounded in-memory deduplication; a fully duplicate delivery emits
no batch. This is not durable recording storage or a route-completeness guarantee.
`receivedAt` is phone/SDK reception time, while each sample's nullable
`sampledAt` is the TAG time. For live `0xD3` samples, `timestampValid` requires
TAG Unix time within seven days before or ten minutes after reception. This is a
live-transport plausibility safeguard, not proof of RTC synchronization. Backlog
records use persistent-record plausibility checks and may be older than seven days.

Live/backlog records share an opaque `stableSampleKey` over the canonical
timestamped firmware record. Hosts compare keys rather than parse them. The
source is `SdkLocationSource.connectedDevice`; `delivery` distinguishes live
from recovered samples. `deviceIdentity` identifies the originating TAG when
available. Classic 12-byte TEL can emit a single-sample batch with null
`sampledAt`; reception time must not be substituted for its missing TAG time.

`syncDevicePositionBacklog(since: ..., until: ..., timeout: ...)` retrieves
retained TAG history through the existing `0xD1` protocol and emits novel samples
on the same stream. Its result reports completion, partial delivery, counts and
the latest processed sample time for inclusive retries. The timeout is an idle
progress timeout; the coordinator also applies an overall bound, currently 12
times that timeout. Successful transfer does not prove every physical sample
was retained. Protocol v1 cannot prove retention loss.

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

## Optional activity recording foundation (AR2A lifecycle + AR2B-P1 storage)

AR1 exports `ActivityRecordingControl`, immutable recording/route models, state
enums and `ActivityRecordingException` from `eixam_connect_core`, also re-exported
through the Flutter package's public entrypoint. Production SDK instances now
implement the optional capability's local, durable metadata lifecycle: start,
immutable verified TAG binding, committed observation, known-ID retrieval,
finish, same-identity restoration and multiple finished-record retention.
AR1's public contract remains unchanged.

AR2B-P1 prepares recording storage through a private native bridge before SQLite
opens: Android uses the SDK subtree under `Context.noBackupFilesDir`; iOS keeps
Application Support and sets/verifies directory backup exclusion. Android's
legacy AR2A directory migrates whole before destination use. Preparation and
migration failures fail closed using existing errors. Consumers need no custom
backup rules or native configuration. This adds no public API or ingestion.

AR2A does **not** ingest TAG positions, calculate distance, detect route gaps or
recover TAG backlog. Empty recordings have zero counters, null distance, unknown
quality and stable route revision zero. Route reads return one terminal empty
page; a mismatched expected revision fails before delivery. History recovery for
a known active recording throws `E_RECORDING_UNAVAILABLE` without claiming work
occurred. Connected, bound input is `unavailable` until ingestion exists; it is
never reported as `observing`. Recovery remains `idle`.

This is not full ActivityRecording production readiness. Commercial integration
belongs to AR3. The sections below preserve the complete public contract,
including route/recovery behavior reserved for later AR2 slices. See
[local engine implementation](../../docs/ACTIVITY_RECORDING_LOCAL_ENGINE.md)
for the delivered lifecycle, ownership, storage and backup limitations.

### Independent domains and optional discovery

- `ActivityAvailabilityControl`: which activity keys the app may offer, through
  the existing unchanged `GET /v1/sdk/activities` endpoint.
- `ActivitySessionControl`: the logical activity explicitly started by the user.
- `ActivityRecordingControl`: an optional local TAG route associated with that
  session, with its own recording ID, lifecycle and device binding.
- Phone Tracking: the separate phone-location lifecycle.

Discover recording with `sdk is ActivityRecordingControl`. No recording methods
are added to the required `EixamConnectSdk` interface or facade. Existing SDK
implementers, test doubles and session/availability consumers need no recording
implementation. `SdkActivitySession` and `ActivitySessionControl` are unchanged.

Recording never starts or stops a logical session, phone Tracking, SOS, DMP or
Protection Mode. It never acquires OTA/provisioning ownership. Hosts separately
coordinate Start/End and preserve their existing DMP End gate. Maps, localized
status, activity catalogs and partner-specific presentation remain host-owned.

### Identity, start and TAG-only binding

Recording requires a trusted current SDK identity. Local ownership distinguishes
installation, backend environment, SDK app and external user, and fences an
established conflicting canonical identity. Signing rotation and temporary
backend unavailability must not prevent trusted same-identity local restoration.
Account/backend/app replacement never migrates a recording. Logout/account
cleanup follows approved identity privacy semantics, including pending results
and observers. Route data must not be dumped into diagnostics.

`startActivityRecording(activitySession: ..., deviceIdentity: ...)` explicitly
associates the current same-identity logical session. The session tuple must
match. `recordingId` is a local SDK recording-domain ID, independent of
`activitySessionId`; AR2 will generate secure random IDs. Activity keys remain
opaque and use the frozen `SdkActivitySession.validateActivityKey` grammar;
there is no recording-specific catalog or second key validator.

A missing TAG does not block recording intent: `active + unbound` or
`active + disconnected` are valid. A known, verifiable disconnected TAG may be
bound. Later binding is explicit through `bindActivityRecordingDevice`; a display
name, list position or merely appearing device never chooses the source.
The bound identity is immutable. Another TAG cannot contribute or replace it;
switching TAG requires another recording lifecycle.

The route is **TAG only**. Phone GPS never fills, extends or reconstructs it.
There is no backend reconstruction or silent fallback source. Only genuine,
validated TAG samples inside the recording window may be accepted or recovered.

### Lifecycle, retention and known-ID recovery

At most **one active/finalizing recording** exists per logical identity.
Repeating Start for the same association returns the existing active recording
unchanged; a different association or conflicting supplied TAG conflicts.
A retained finished association cannot silently restart.

**Multiple finished recordings are retained locally.** Completing another
recording never deletes earlier finished recordings. No arbitrary automatic
age-based deletion is specified. Storage exhaustion must be explicit/degraded,
without silently deleting active or finished routes. Storage representation,
limits and benchmarks belong to AR2. Credentials/identity metadata stay separate
from route-volume storage; large routes do not belong in SharedPreferences or
Keychain/SecureStorage. The commercial app must not create a second route store.

`finishActivityRecording(recordingId: ..., endedAt: ...)` fixes the recording
cutoff before bounded final reconciliation. Repeating finish for any retained
matching ID returns the original result without changing its cutoff or touching
another active recording. Missing IDs produce `E_RECORDING_NOT_FOUND`.

`getActivityRecording(recordingId: ...)` retrieves a known active/finalizing or
retained finished result for finish idempotence, navigation, immediate summary
or crash recovery. It returns null only for confirmed absence within the current
identity, not a storage failure. There is no latest-only result assumption.
There is no recording list/search/history API and no History UI in this stage.

`getActiveActivityRecording()` and `watchActiveActivityRecording()` expose only
active/finalizing state. The watcher seeds committed state and then committed
changes; restore failures are errors, never fabricated null/empty state. Identity
changes fence buffered values, errors and route pages. Process recreation must
preserve active metadata/route rather than automatically finish the recording;
runtime downtime remains uncertain until genuine TAG evidence can reconcile it.
Continuous recording while the process is killed is not promised.

### Orthogonal facts and honest metrics

`SdkActivityRecording` contains identity/summary facts, not route arrays:

| Fact | Values / meaning |
| --- | --- |
| `phase` | `active`, `finalizing`, `finished` |
| `inputState` | `unbound`, `disconnected`, `observing`, `unavailable` |
| `recoveryState` | `idle`, `recovering`, `deferred` |
| `routeQuality` | `unknown`, `partial`; never guaranteed complete |
| `issues` | Immutable current degradation facts, not permanent error history |

`observing` means the matching input path is attached, not that fresh GPS fixes
are arriving. Use original `firstSampleAt`/`lastSampleAt` for sample coverage and
freshness. `idle` recovery does not prove completeness. Partial quality means a
known interval lacks defensible continuity; unknown means no such interval is
currently known, while completeness remains unproven.

Gap states are `pending`, `recovering`, `unresolved` and `reconciled`. Reasons
describe unavailable device/runtime, rejected samples, ambiguous timestamp or
persistence failure. Reconciled means retained evidence supports continuity for
that interval, not that every physical route sample was captured. A successful
backlog transfer or a single interior recovered point is insufficient by itself.
`recoverActivityRecordingHistory` requests/coalesces a bounded TAG reconciliation
episode; unavailable recovery is deferred, not a fatal disconnect error.

`recordedDistanceMeters` is nullable **recorded route distance**, not exact
movement or sports-grade distance. Null means no defensible distance edge exists,
including empty/one-point routes. A genuine zero requires eligible accepted edges
that total zero. AR2 will calculate horizontal Haversine chords between adjacent
accepted points within canonical continuity segments, never across pending,
recovering or unresolved gaps. Duplicates add nothing; chronological recovered
insertion changes affected edges. Altitude contributes no distance.

Time facts remain distinct:

- `activitySessionStartedAt`: logical session start; the canonical source for
  Activity elapsed remains `SdkActivitySession.startedAt`.
- `recordingStartedAt`: recording acceptance/persistence window start, possibly
  later than the session and unchanged while waiting for a TAG.
- `endedAt`: fixed recording cutoff when finalizing/finished; not the logical
  session's private ended timestamp. Omitted finish cutoff uses command acceptance
  time; explicit cutoff cannot precede recording start or lie in the future.

The sample span is not recorded duration or moving time. V1 supplies no
ascent/descent, speed, pace, calories or moving-time metrics. Real coarse altitude
may be retained per point without promoting it to an elevation metric.

### Finite paged route reads

`readActivityRecordingRoute(recordingId: ..., fromInclusive: ...,
expectedRouteRevision: ..., pageSize: 512)` pages one known route, not activities.
Each finite read captures a consistent local route revision when listened to.
An empty route still emits a terminal page. Cancellation releases read resources.
A nonpositive page size is invalid; page size bounds points per page.

`SdkActivityRoutePoint` retains opaque sample identity, original UTC TAG time,
coordinates, optional coarse altitude and existing `EixamDevicePositionDelivery`
live/recovered provenance. It has no phone-source or presentation fields.
`SdkActivityRouteSegment` is a canonical continuity group, not a styled polyline.
Pages may split a logical segment; equal `segmentId` identifies continuation at
that revision. Page boundaries never create gaps.

`SdkActivityRouteGap` carries UTC `from`, optional open `until`, domain reason
and reconciliation state, including uncertainty before/after available points.
Page `segments`/`gaps`, segment `points` and recording `issues` defensively copy
their input collections and cannot be mutated externally. Models normalize UTC
timestamps but do not implement runtime lifecycle or ingestion validation. They
follow the existing activity models' identity equality and omit copy/serialization
frameworks and route-bearing diagnostic string representations.

`routeRevision` and `previousRouteRevision` describe local route/gap mutations,
not cloud synchronization. `routeChangedFrom` identifies the earliest affected
timestamp for the most recent mutation. Metadata-only observations do not invent
a new route mutation. `fromInclusive` supports replacing a route suffix,
including overlapping gaps. A consumer missing the previous revision must refresh
rather than merge that suffix. A mismatched expected revision produces retryable
`E_RECORDING_ROUTE_REVISION_CHANGED` before any page is delivered.

### Errors and implementation boundary

`ActivityRecordingException implements Exception` exposes stable `code` and
`message`, independently of the sealed SDK exception hierarchy. Initial contract
codes cover conflict, session mismatch, missing identity, device mismatch, invalid
time, missing ID, already finished, changed route revision and unavailable
capability/runtime. AR2A adds concrete runtime failures through that existing
exception: `E_RECORDING_RESTORE_FAILED` for unreadable/corrupt/unsupported local
storage and `E_RECORDING_PERSISTENCE_FAILED` for a failed transaction or cleanup.
Messages exclude database payloads. No public type or required SDK method changes.

All recording metadata, points, gaps, metrics, recovery facts, finished results
and summaries are local-only. No recording endpoint, upload, cloud sync, server
history, remote URL or background recording upload is introduced. Existing remote
activity availability remains separate and unchanged. The public contract has no
backend IDs, cloud state, partner IDs or activity-specific branches.
