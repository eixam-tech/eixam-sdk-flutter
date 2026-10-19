# Activity Recording local engine (AR2A + AR2B + AR2C-A + AR2C-B + AR2D fixes)

The SDK implements durable recording lifecycle and live TAG route persistence
behind the frozen optional `ActivityRecordingControl` contract. AR2B adds live
D3 ingestion, durable sample identity, canonical order/segments, conservative
integrity gaps, route distance and paged reads. AR2B-P1 backup-safe storage remains
unchanged. AR2C-A adds authoritative disconnect uncertainty, bounded retained
D1 recovery through the existing coordinator, durable live/recovered dedupe and
conservative gap reconciliation. AR2C-B adds robust bounded final catch-up and
immutable partial results with durable process/offline restoration. There is no
commercial host integration, complete-route guarantee, cloud synchronization or
route upload.

## Storage and dependencies

The Flutter SDK owns `sqflite` 2.4.2 and `path_provider` ^2.1.5. Consumers do not
provide an app database or inherit app-level Drift/sqflite configuration. Sqflite
is maintained in [tekartik/sqflite](https://github.com/tekartik/sqflite), supports
Android/iOS/macOS, and uses the platform SQLite implementation. The SDK's
supported native targets remain Android and iOS. Desktop FFI SQLite is a test
dependency, not a new production desktop capability.

Sqflite and Flutter's path_provider use BSD licenses. SQLite is not encrypted by
this implementation. Dependencies register through Flutter's ordinary plugin
build; there is no manual database initialization, permission, CocoaPods edit or
host API required. Native dependencies change the consumer build and require a
normal rebuild. The current lock resolves path_provider 2.1.6, whose Android
implementation uses Flutter JNI support; it registers automatically. The
path_provider_foundation 2.5.1 development pin avoids newer Darwin host-test hooks.
These host tests do not prove Android/iOS linkage or physical-device behavior;
native consumer build/smoke validation remains a release check.

The SDK-private `ActivityRecordingStorageDirectory` calls the plugin's private
recording-storage bridge before SQLite opens. It resolves and prepares:

- Android: `<Context.noBackupFilesDir>/eixam/activity_recordings/recordings.sqlite`.
- iOS: `<ApplicationSupport>/eixam/activity_recordings/recordings.sqlite`, after
  setting and reading back `URLResourceValues.isExcludedFromBackup == true` on
  the recording directory.

Both locations are durable app-private storage, not cache, Documents or external
storage. Absolute container paths are recomputed at runtime and are never stored
as recording identity. Preparation failure throws the existing sanitized
`E_RECORDING_PERSISTENCE_FAILED`; it never falls back to backup-eligible storage.
Identity cleanup also prepares the directory before inspecting an existing file;
it does not create a database when none exists. The public SDK disposal path
closes the store without deleting it.

The private native resolver replaces path_provider's production recording-path
role. The existing path_provider dependency and development pin are retained in
this bounded correction to avoid unrelated dependency/native registration graph
changes; host tests still use its platform test seam. Consumers need no recording
backup rules, manifest/Info.plist flags, native setup or public initialization API.
The bridge registers through the existing SDK plugin; normal rebuild is required.

Metadata contains a SHA-256 principal namespace and established canonical user
IDs, never signing hashes, credentials or authentication secrets. The default
native database factory opens lazily, enables foreign keys, WAL and FULL
synchronous commits.

### Android migration from AR2A

Before destination SQLite use, the SDK checks the legacy
`<Context.filesDir>/eixam/activity_recordings` directory. If absent, it creates or
uses the no-backup directory. A closed legacy directory is validated and moved
whole with `android.system.Os.rename`, preserving DB, WAL, SHM and other recording
metadata. Source and destination parent must have the same filesystem device;
there is no copy fallback. The [POSIX rename semantics](https://pubs.opengroup.org/onlinepubs/9799919799/functions/rename.html)
provide atomic same-filesystem replacement: an
interruption leaves the source or destination directory, and the next preparation
uses that state. No persistent migration marker or absolute-path identity is
needed.

If both locations exist, preparation fails without merging, overwriting or
removing either. Invalid/corrupt/unsupported source databases, orphan sidecars,
aliased artifacts, inaccessible roots or rename failures also fail closed.
Source validation uses a nondeleting corruption handler and checks schema
version, integrity and required tables. There is no destructive reset. The
supported writer model remains one Dart isolate/controller; this is not a
cross-isolate/process migration-lock protocol. An app update terminates the old
binary before the new implementation opens its store. iOS keeps its existing
path and applies exclusion in place without moving existing metadata.

## Schema version 2

| Table | Purpose |
| --- | --- |
| `recording_store_metadata` | Singleton ownership namespace and established canonical IDs |
| `recordings` | Recording ID, immutable logical session tuple, owner, optional TAG, timestamps, lifecycle, issues, counters and revision |
| `route_points` | Accepted TAG sample facts, bound device, integer UTC ordering, segment ID, predecessor key and nullable inbound horizontal distance |
| `route_gaps` | Integrity and disconnect intervals with reason/state and indexed UTC boundaries |
| `recording_recovery` | Recording-owned durable recovery need and inclusive processed-history cursor |

SQLite's `user_version` is the explicit schema version (currently 4). Version 1 to 2 migrates
transactionally without resetting metadata, bindings, active/finalizing or
finished recordings. Approved v1 route tables are empty; unexpected legacy route
evidence aborts migration and preserves the original database. Version 2 adds
integer microsecond ordering, device/predecessor/edge facts, gap boundary indexes
and a private distance-edge counter. The recording's immutable binding scopes the
existing `(recording_id, sample_key)` unique key; device identity is also persisted
and verified per point. Version 2 to 3 adds the recovery table without rewriting
existing summary/point/gap rows. Existing unresolved gaps seed durable recovery
need. Accepted v1 metadata migrates through both steps in the same transaction.
Version 3 to 4 adds nullable private finalization start/deadline columns to
`recordings`. Older active/finished rows and all route/recovery facts are retained;
legacy finalizing rows with no timing proof complete without waiting. Creation
and every accepted v1/v2/v3 migration are transactional.
There are no destructive migration fallbacks. Unsupported older/future versions
fail closed and preserve the file. Future versions must supply transactional
migrations and extend the metadata mapper and route reader together. A route
table containing data cannot currently be advertised as an empty route.

A partial unique index permits at most one active/finalizing recording per
owner. Another unique constraint prevents recording the same logical session
twice. Finished rows have no age or count limit and are never replaced by the
latest result. Points/gaps reference recordings with cascading foreign keys;
identity cleanup explicitly deletes all child rows, recordings and metadata in
one transaction, including malformed child rows without valid references.

One controller owns mutations per store namespace in one Dart isolate. A private
actor serializes operations; an isolate-local writer lease rejects a second
controller until disposal releases ownership. Cross-isolate mutation is not
supported. SQLite transactions are not a distributed ownership protocol.

## Lifecycle and observation

Start validates trusted identity and the exact currently active ActivitySession
tuple while holding the logical session's command queue. It never starts, ends
or writes an ActivitySession. A new recording gets 128 bits from `Random.secure`
and is published only after commit. Identical start is idempotent; another
active/finalizing recording conflicts. A retained finished session cannot restart.

Unbound start is valid. Initial binding requires an exact normalized canonical
hardware identity from the current paired runtime status and a registry
assignment verified in the same SDK identity generation. Preferred device IDs,
advertised IDs, names and list ordering are insufficient. Asynchronous assignment
results from a prior identity cannot establish proof. Provisioning's legacy
assignment cache alone is not recording proof. If current evidence is missing,
binding returns `E_RECORDING_DEVICE_MISMATCH`; no remote request is initiated by
the recorder. A committed binding is immutable and restores offline without
reverification. Same-binding retries are idempotent. A disconnected verified TAG
has `disconnected` input. A matching admitted live D3 path establishes
`observing`, which describes attachment rather than fresh GPS. AR2C-A also uses
authoritative matching TAG connection facts to restore `observing`. Reconstructed
runtimes conservatively restore previously attached input as `disconnected` until
current evidence arrives. A persisted attachment alone does not invent a new gap;
an authoritative current loss/disconnect fact does. Sparse fixes never establish
a disconnect.

Finish commits `finalizing` with a frozen UTC cutoff and private five-second
absolute deadline, then attempts eligible final catch-up outside the serialized
recorder actor. The default cutoff is SDK acceptance time; explicit cutoffs
cannot precede recording start or be in the future when first accepted. Samples
already received after a caller's earlier cutoff are clipped transactionally
with gaps, metrics and summary. During finalizing, eligible live/recovered samples
at or before the cutoff remain admissible. Later data is rejected.

The final actor turn drains previously accepted ingestion, fences recording-owned
recovery and commits `finished` atomically. Repeated retained finished IDs return
the original result even if another recording has an orphaned association.
Different explicit cutoffs throw `E_RECORDING_INVALID_TIME` for both finalizing
and finished records. Reconstruction resumes the original intent/deadline;
disconnected or expired restoration completes without a device wait. See the
AR2C-B section for timing, terminal projection, failures and proof limits.

Known-ID lookup returns active/finalizing/finished metadata or null for an
unknown ID within the current owner. Active lookup returns null only after a
successful authoritative read. Missing identity on a known-ID request throws
`E_RECORDING_IDENTITY_REQUIRED`. Corruption is never converted to absence.

Watchers seed committed state and emit active/finalizing metadata, then null at
finish. Callback-based subscription ownership permits prompt cancellation,
including paused subscriptions; there is no nested async-generator subscription.
Every value and error is generation-fenced at publication and delivery.
Idempotent mutation retries reconcile lost commit acknowledgements without
speculative events. Dispose fences commands immediately, drains in-flight SQL,
closes observers and releases the writer lease. New writes cannot commit after
disposal completes.

## Identity and restoration

Ownership scopes normalized backend namespace, SDK app and external user;
canonical SDK/external user evidence is retained when established. Same-principal
signing rotation and temporary canonical endpoint failure preserve state.
Trusted offline reconstruction uses local ownership and ActivitySession state,
without waiting for backend readiness. A missing, different, corrupt or unreadable
logical session causes `E_RECORDING_SESSION_MISMATCH` on active lookup/watch or
bind/start validation. Recording facts remain readable by known ID; explicit
finish remains available. Restoration never silently reattaches or finishes an
active orphan. A previously committed finalizing intent still completes.

Logout, backend/app/user replacement and confirmed canonical conflict fence
commands, queued writes, delayed verifier callbacks and watcher events
immediately. Prior-owner active, finished, route and metadata rows are purged.
Canonical conflicts detected during persisted-owner reconciliation commit the
purge and then reject access. Failed cleanup returns a typed persistence error
and quarantines access; subsequent access must successfully retry the purge
before adopting the next identity. Different-owner lookup never reveals whether
a prior ID existed. Ordinary SDK disposal preserves data.

The reader validates ownership shape, association fields, canonical binding,
UTC timestamps, enum/state consistency and route-summary invariants. Stored
edge counts must agree with null/numeric distance; paged points also validate
bound device, UTC ordering, recording window and geographic bounds.
Malformed ownership is a restore error, not an identity change that authorizes
deletion. There is no ordinary-access database reset. SQLite errors are sanitized
at the private boundary and no recording SQL/identity/route payload is logged.

## Live source and durable ingestion

The production SDK taps already decoded `EixamTelLiveBatchPacket` D3 evidence
before `DevicePositionBatchNormalizer` transient/public dedupe. The existing
public batch stream and dedupe behavior are unchanged. Retransmitted decoded
samples can therefore retry recording persistence even when their public event
has already been suppressed. SQLite is the recorder's durable ledger.

Admission requires current paired/connected canonical physical identity and every
D3 node matching the current TAG path. The controller captures identity generation
synchronously, serializes with lifecycle/identity commands, validates the logical
session and immutable bound device, then calls `ActivityRecordingIngestor`.
Unbound recordings never auto-bind. Wrong device/source/recovered delivery is
ignored without route mutation. Only connected-device, live TAG sample evidence
is accepted. Classic TEL has no defensible sample timestamp and is excluded;
D1 history, SOS/relay, phone, backend and resolved-location fallbacks are excluded.
No packet decoding is duplicated inside ActivityRecording.

Sample time is the genuine TAG UTC value, never reception-time substitution or
clamping. It must be at/after recording start and pass the existing D3 seven-day
past/ten-minute future plausibility bounds, plus the runtime future bound. Invalid
or missing timestamps cannot become points. Valid in-window timestamps paired
with invalid geographic/altitude evidence declare a rejected-sample interval.
Coordinates reuse `EixamGeoCoordinates`, including finite/range/Null Island rules.
Raw coarse TAG altitude is retained but contributes to no metric.

Each batch commits accepted points, sample identity, topology, issues and summary
in one transaction. Identical duplicate content is a no-op across batches and
restarts. A conflicting key preserves its first committed value and declares an
unresolved rejected-sample interval; it never overwrites or invents movement.
Same-timestamp distinct keys are retained in deterministic key order and declare
ambiguous continuity. Missing time, wrong source/device and outside-window
rejections do not manufacture gaps. Sparse sampling alone creates no gap.

Normal append touches the existing tail and new rows. Out-of-order insertion
repairs canonical predecessor edges and segment labels in affected intervals;
unchanged edges reuse persisted distance. AR2D-FIX2 replaces unconditional suffix
materialization with bounded internal repair batches. A simple insertion between
A and C replaces A-to-C with A-to-B and B-to-C. Repair stops beyond the mutation
interval only when persisted predecessor, segment ID and edge distance match the
canonical result. Coordinates of existing samples remain immutable, so those
facts prove downstream continuity is unchanged. Overlapping/adjacent mutations
coalesce; disjoint intervals use the preceding interval's repaired context.

Changed gaps or segment identities can require broader traversal until the same
stability condition holds. Pending-to-unresolved gap-state changes preserve edge
blocking, so they use local context while still committing their public revision. Integrity gaps ending at a context predecessor still
block its outgoing edge; they must not disappear behind the repair start bound.
Same-timestamp ambiguity, reconciliation proof, deterministic segment IDs,
distance, revision and earliest changed predecessor retain their canonical
semantics. Internal repair batching does not change public route paging SQL,
page size or stream ownership.

Summaries publish only after commit. Failed or ambiguous acknowledgements expose sanitized recording errors; retry/restoration
reads authoritative SQL state without double-counting. Failed writes never
advance durable identity, route revision or observer counts.

### Persisted integrity and fail-closed behavior

Persisted rows are not trusted merely because SQLite accepted them. Route rows
validate sample keys and canonical segment IDs before dedupe/topology use or page
composition, alongside UTC/window, device and geographic checks. Local repair
validates the rows it consumes rather than scanning/materializing an otherwise
unaffected route. The empty-key metadata guard uses the existing primary key.

All gaps for an authorized recording validate before overlap, reason or state
filtering. Canonical UTC text and integer boundaries must represent the same
instant, nullability must agree, and closed intervals must be ordered. IDs,
reason/state enums and lifecycle-appropriate open/closed boundaries must be valid.
This prevents malformed numeric bounds from hiding an overlapping public gap.

A non-null processed recovery cursor must be an integer timestamp within the
recording's durable start/last-sample/end window. It is validated before recovery
filtering or mutation; wall-clock rollback is not treated as corruption. A user
Finish cutoff can legitimately narrow an already validated cursor together with
the retained samples, atomically. This is not a clamp of corrupt input. Finish
also validates identifiers before clipping/deleting rows or aggregating topology.

Malformed facts fail with existing sanitized restore/persistence errors. Active
corruption is not reported as an absent recording. Rejected operations retain
the original evidence and roll back partial mutations; they perform no automatic
repair, reset, deletion or schema recreation. Ownership reconciliation and
identity fencing precede validation. Schema version four, native backup
exclusions, local retention and backend independence remain unchanged.

## Route topology, distance and revisions

Chronology is integer UTC microseconds with stable sample-key tie-breaking;
variable ISO fractional precision never determines ordering. Segment IDs are
opaque deterministic recording/sample-derived identities. Eligible edges join
adjacent unique-time TAG points within one continuity group. A proven rejected or
ambiguous interval removes every crossing/incident edge and splits segments.
Unresolved gaps imply `partial`; otherwise quality stays `unknown`. Completeness
is never claimed. Current issues are bounded enum facts, not an event history.

`recordedDistanceMeters` sums horizontal Haversine edges with radius 6,371,000 m.
It uses no altitude, phone GPS, smoothing, map matching or speed filter. Sparse
samples contribute straight Haversine edges only where continuity is defensible.
No eligible edge means null, including empty/one-point or wholly disconnected
routes. A numeric 0.0 requires at least one real eligible zero-length edge.
Out-of-order insertion replaces the affected old neighbour edge with new edges;
point/topology/distance/revision changes share the same transaction.

A route starts at revision zero. A committed batch with canonical point/gap
changes increments once; `previousRouteRevision` is its prior value and
`routeChangedFrom` includes the earliest affected predecessor/gap boundary.
Identical duplicates, wrong TAGs, input/lifecycle-only changes and rejections
without persisted topology change do not increment. Explicit finish clipping
increments once only when it changes canonical route data.

## Paged route reads and restoration

A route read captures its revision in the first successful page transaction.
Each page uses one recorder command and one SQLite transaction: ownership and
current recording metadata are loaded, the captured revision is checked, and the
page is read atomically. The transaction and command finish before stream page
delivery. The existing cursor and page-size bound remain unchanged.

Consumer pause/resume waits outside the recorder actor and database transaction.
A paused reader retains only lightweight Dart stream/cursor state; it retains no
native cursor, historical database snapshot or WAL end mark. Live writes,
recovery, finish cutoff persistence and finalization commits do not wait for
consumer resume/cancellation. An executing page still takes its ordinary finite
SQL/actor time. At most one page command per reader is outstanding; no reader
lease, timeout, admission limit or additional database connection is introduced.

An initial `expectedRouteRevision` mismatch fails before page delivery. A route
mutation between pages terminates the read with the existing
`E_RECORDING_ROUTE_REVISION_CHANGED` before any page from the new revision is
delivered. Already delivered pages all belong to the captured revision. Consumers
refresh recording state and begin a new read; they must not treat a failed read
as a completed route/suffix replacement or continue its cursor at a new revision.
Metadata-only changes and identical sample replays preserve the read when they
leave `routeRevision` unchanged. Unknown IDs fail; ownership is checked before
reading data.

Cancellation wakes a paused producer, prevents subsequent page commands and
suppresses pending delivery. Identity replacement and SDK disposal immediately
fence the reader. They drain only any finite page operation already executing;
cleanup never awaits paused stream event delivery. Normal completion unregisters
the reader and closes its stream.

`pageSize` bounds combined point/gap entries. Segments may continue across pages
with the same ID; clients concatenate consecutive matching fragments. No boundary
points are duplicated. `fromInclusive` returns points at/after its timestamp and
gaps overlapping that suffix, including intervals beginning earlier. An empty
read still emits one terminal page. Summaries contain no route arrays.

Same-principal/cold-offline reconstruction restores points, topology, binding,
distance and revisions without a backend request. Multiple finished routes remain
independently retrievable; later live deliveries cannot change finished data.
Identity cleanup removes prior-owner points/gaps along with metadata, and late
old-generation callbacks/pages cannot expose coordinates to a replacement owner.

AR2C-A implements retained D1 recovery as described below. AR2C-B adds bounded
final catch-up, disconnected finish and immutable partial results.
Ascent/descent, speed/pace/calories and complete-route guarantees remain
unimplemented. The recorder never owns Tracking, SOS, DMP, Protection, OTA or
provisioning actions.

## Backup and data protection limits

Recordings remain local-only: no backend upload, cloud synchronization or
Eixam-managed remote persistence. AR2B-P1 establishes the supported OS exclusion
mechanism before any default-path recording database open.

[Android Auto Backup](https://developer.android.com/identity/data/autobackup)
always excludes `Context.getNoBackupFilesDir()` from normal cloud backup and
device transfer, even if a consumer tries to include it. Storage does not depend
on host `allowBackup`, `fullBackupContent` or `dataExtractionRules` settings and
does not disable backup for the rest of the host application.

[Apple's backup guidance](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup)
explicitly supports grouping related files in an excluded directory. The
recording directory's exclusion covers its DB, WAL, SHM and future children;
individual child URL resource values may still be false because they are not
an inherited-policy measurement. The SDK reapplies and verifies the directory
value on each preparation, including after recreation. Apple describes this
property as guidance to the system, not a guarantee that data can never appear
in any backup or restored device. This implementation makes no stronger claim.

This is not encryption, secure erasure or a new iOS file-protection class.
OS/device protection inherits host defaults. SQL cleanup is logical deletion,
not a forensic secure-erasure guarantee for free pages/WAL. No real coordinates
were introduced by AR2A or P1. Actual Google cloud/device-transfer and iCloud
account restore cycles and physical-device protection remain unverified.

## Validation scope

Deterministic tests exercise the production SQL implementation using host SQLite
FFI in per-test temporary directories. Coverage includes lifecycle, A/B/C finished
retention after reconstruction, finalizing crash recovery, canonical proof,
cold offline production SDK composition, signing rotation, replacement/logout,
cleanup quarantine, delayed writes/callbacks, paused watchers, ambiguous commit
acknowledgements, corruption, future schema, duplicate-active rejection, rollback
and SQLite disk-full rollback. Safety spies reject recording-triggered Tracking,
SOS, DMP, Protection, OTA, provisioning and public position-stream orchestration.
AR2C-A exercises the private existing backlog coordinator; it does not invoke a
host/public backlog override or displace another transfer.

The metadata benchmark tests measure open, start, lookup, finish and restore with
1/100/1000 finished rows. They impose no timing SLA or retention limit. These are
host metadata measurements, not mobile/route-volume or power benchmarks. P1
native validation used disposable consumers, never production host changes:

- Android API 35, host `allowBackup=true`, JVM 17 targets, AGP 8.13.2/Gradle 8.14:
  debug APK/plugin registration, actual `Context.noBackupFilesDir` subtree and
  same-volume inspection, commit/rollback/reopen/process restart passed. A closed
  real SQLite fixture with an uncheckpointed WAL migrated two synthetic finished
  rows. Both-path conflict and corrupt source failed without deleting evidence;
  source-absent preparation also passed. Route tables stayed empty.
  A local Backup Manager transport probe was attempted. Android rejected this
  disposable package with `Backup is not allowed`; a normal-files control was
  not restored, so this is not successful backup/restore evidence. Temporary
  backup-manager settings were restored. Classification relies on the native
  path proof and the documented platform exclusion semantics.
- iOS 26.5 arm64 simulator, Xcode 27.1/CocoaPods 1.16.2: build/registration,
  commit/rollback/reopen/process restart and existing AR2A metadata passed. Native
  inspection while SQLite was open read directory exclusion `true`; DB/WAL/SHM
  existed beneath it, each with its own resource flag `false`. No sidecar escaped
  the directory. The simulator reported no file-protection class, which is not
  physical-device protection evidence.
- Private tests cover native migration interruption before/after rename,
  conflict/corruption/preparation failure, nondeletion and per-engine channel
  ownership; Foundation tests cover actual resource readback, recreation and
  setter/readback failures. Dart tests prove preparation precedes SQLite and
  failure permits zero SQLite opens, with no fallback.

x86_64 simulator remains unverified because of the P0 Flutter packaging/tooling
limitation; arm64 is the proven current consumer path. This is nonblocking for
this bounded correction, not a new desktop/architecture support claim. Future
Kotlin Gradle plugin compatibility and SwiftPM support warnings remain unrelated
tooling debt. Route-volume, power and physical-device benchmarks remain future
work.

Accepted P1 automated validation: Core analysis clean and 234 tests passed; Flutter
analysis retained seven pre-existing infos with no errors/warnings and 1,991 tests
passed; UI analysis clean and nine tests passed. The explicit AR2A/new-storage
suite plus public-export compatibility passed 85 tests (76 AR2A, eight storage,
one export). Android JVM tests passed 140 cases, including 13 new storage cases;
the standalone Foundation helper executable passed eight cases. No final test
failures or skipped tests were reported. Native tests use synthetic metadata
only, with route points/gaps zero and distance null.


## AR2B validation evidence

Tests cover source/device/window filtering, genuine null/zero distance,
independently checked Haversine values, microsecond ordering, duplicate and
conflicting keys, equal times, topology splits, out-of-order bursts, committed
watchers, paging/suffix consistency and cancellation, schema migration, all
finished routes, identity fencing/cleanup, offline restore, real SQL rollback and
lost acknowledgements. Production-composition tests prove recorder retry through
both exact D3 replay and Classic-to-D3 public suppression; safety/backlog spies
remain zero.

Host SQLite measurements, using 24-point live batches (microseconds):

| Points | Ingest | Summary | Full paged read | One append | Middle insertion | Restore | RSS change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 453,126 | 4,252 | 11,016 | 2,842 | 3,693 | 5,217 | 20,316,160 B |
| 10,000 | 2,981,687 | 529 | 44,747 | 1,938 | 15,506 | 4,855 | 10,993,664 B |
| 100,000 | 32,038,116 | 466 | 2,705,980 | 4,265 | 87,957 | 7,954 | 53,035,008 B |

These are host process/SQLite measurements, not mobile latency/power guarantees
or retention limits. These historical middle-insertion measurements include full
suffix inspection; AR2D-FIX2 localizes that repair without introducing a product
point limit. Native physical acceptance is recorded separately from these synthetic measurements.

Final AR2B automated validation: Core analysis clean, 234 tests passed; Flutter
analysis reports the same seven pre-existing infos, no errors/warnings (strict
analyzer exit 1), and 2,033 tests passed with zero failures/skips; UI analysis
clean, nine tests passed. The new coverage comprises 29 ingestion tests, four
migration tests, three route benchmarks and six additional SDK composition
tests. Android JVM tests passed 140 cases; the standalone Foundation storage
helper passed eight cases. Public Core/UI contracts and exports are unchanged.

Disposable native synthetic probes passed on Android API 35 and iOS 26.5 arm64
simulator, using byte-identical SDK sources. Their boundary is the authoritative
D3 decoder through the private ingestor to default native-prepared SQLite; full
SDK/controller composition is covered separately by package tests. Each platform
persisted three reverse-arrival points as one chronological segment, paged them
in two pages, and matched an independent horizontal Haversine calculation. Real
SQL rollback followed by identical retry, durable duplicate no-op, empty accepted
schema 1 to 2 migration, and process restart before any new delivery passed.
Android DB/WAL/SHM stayed under the native no-backup directory; iOS directory
exclusion was true before SQLite opened and while sidecars existed. These checks
do not establish actual cloud/device-transfer restore or physical protection.

### AR2B-HW1 — REAL TAG D3 ACCEPTANCE

**PHYSICAL D3 VALIDATION: DEFERRED.** AR2B implementation and automated/native
synthetic evidence are accepted for continued feature development. Real live D3
admission into ActivityRecording has not been physically validated.

The physical Android attempt timed out establishing GATT; recorder admission was
not reached. The physical iOS probe connected to the expected TAG, verified its
runtime node against USB identity, and received two Classic TEL events, but
observed zero eligible D3 packets and zero points. The installed firmware supports
D3 and requires fresh TAG GNSS fixes and movement; an outdoor movement test could
not be performed. No evidence currently indicates an ActivityRecording defect.
The missing proof is environmental/device-delivery validation, not a known
implementation failure. Temporary probes are isolated from commercial hosts;
no reception-time, inferred-timestamp, phone GPS or backend-location fallback is
permitted. Classic TEL without a defensible sample timestamp remains rejected.

AR2B-HW1 is a hard release/QA gate that must pass **before final M6 sign-off,
M6C, merge to develop, or release/store distribution**. Required eventual proof:

REAL TAG → genuine live D3 → decoder → ActivityRecording ingestor → persisted
route → non-null recorded distance → public route API → process restart → same
route restored. Prefer at least three valid D3 points with actual movement, and
compare persisted coordinates with the TAG source. No real-route distance or
real-route restart acceptance is claimed until this gate passes. Deferring this
gate permits continued SDK development; it does not waive release acceptance.


## AR2C-A disconnect and recovery

The production current-device projection supplies canonical TAG identity and
connection facts. Loss of the bound path opens `deviceUnavailable` uncertainty;
replacement of a previously observed bound path by a different current TAG also
stops that path. An unrelated TAG cannot close a gap or change the binding.
The boundary is the last accepted sample, or recording start for leading loss.
The SDK captures the observed reconnect time before queueing persistence. A
clock rollback before the lower boundary leaves the gap open. Loss is never
inferred from GPS cadence, a stale fix, or backend availability.

Disconnect leaves the recording active and bound. It persists a pending, open
gap and deferred recovery need. Reconnect closes the observed interval and
restores observing; it does not prove continuity. Edges ending at the last
pre-disconnect sample remain valid. Edges crossing an unreconciled disconnect
interval are excluded, including newly recovered points inside that interval.
Integrity gaps retain their stricter closed-boundary rules.

### Episodes and command ownership

The recorder uses `DevicePositionBacklogCoordinator.syncRecording`, a private
lease on the existing D1 coordinator. The public backlog signature, normalization,
deduplication and timeout policy are unchanged. Recording sees genuine decoded
D1 chunks before public transport dedupe and awaits its SQLite transaction before
ACK/END processing. Decoding remains in the existing protocol implementation.

Triggers are matching reconnect, a current command/assignment readiness edge,
reconstruction with durable pending work, an existing SDK foreground-resume
transition, and explicit `recoverActivityRecordingHistory(recordingId)`. Repeated
resumed notifications do not rearm an episode. Existing runtime capability
refreshes also reconcile readiness. There is no app lifecycle dependency, new
polling, periodic timer, or automatic rearming after exhaustion without a future
eligibility edge or explicit request. Duplicate triggers share one episode.

Defaults are an immediate attempt and at most two retries after 1 s and 5 s.
A recording-owned 60 s timer bounds the whole episode, including retries and
progressing transfers. Every attempt receives only the remaining budget, rather
than the public coordinator's 12-times-idle budget. The 5 s idle timeout still
applies inside an attempt. Timer creation is a private deterministic test seam.

Protection/native BLE ownership, OTA, provisioning, an absent command path or
an already active backlog transfer defer recovery. The recorder does not acquire
ownership or cancel another subsystem/transfer. A lease token permits cancelling
only the recording's transfer. Temporary command/connection loss returns committed
deferred state for the same active recording. Identity replacement, disposal or
finish fences the old episode and its explicit caller. Finish performs no final
history request.

`recovering` is summary state while an episode runs. Gap rows keep pending or
unresolved state during transfer; this implementation does not publish transient
`recovering` gap rows. Settling changes a pending gap to unresolved or reconciled.
Each visible gap change increments route revision once with topology/distance
repair in that transaction. Recovery/input/issue-only changes do not increment
route revision. Identical point replays and repeated unchanged unresolved results
also leave revision unchanged.

### Acceptance, cursor and proof

Acceptance requires the current principal, recording, immutable canonical TAG,
current connection/recovery generation, and genuine coordinator-delivered D1
provenance. Production also checks the decoded TEL node against current runtime
node identity. Sample UTC must be defensible, inside the recording and the
captured recovery window, with a durable sample key and valid coordinates.
Classic TEL, phone/backend locations and reception timestamps remain excluded.

D1 and D3 share the same durable `(recording_id, sample_key)` ledger. Delivery
provenance is the first committed delivery and is not content inequality.
Conflicting coordinates/time/altitude preserve the first committed value and
persist integrity uncertainty. An intersecting unresolved integrity gap prevents
disconnect reconciliation even on a later duplicate-only transfer.

The private cursor is inclusive and advances only on a complete accepted D1
transfer, after all relevant samples have durably committed. It records the last
processed retained sample time, never command receipt or a newer live tail.
The next request starts at the earlier of this cursor and the oldest unresolved
gap, or recording start if neither exists. Partial/failed transfers retain their
committed points and replay inclusively from the prior cursor/gap on retry.
They do not advance coverage past failed or undurably processed evidence.
Empty history cannot advance the cursor or prove a disconnect interval.

A closed disconnect gap reconciles only if all of these hold in one episode's
successful attempt:

- META describes a contiguous logical-index range and all expected CHUNK indexes
  and successful END totals validate in the existing coordinator.
- Every relevant delivered in-window sample is accepted durably without rejected
  coordinates/time, conflicting identity content, or unprocessed evidence.
- Retained sample times span both boundaries: earliest <= gap.from and latest >=
  gap.until, with at least two distinct times. One interior point is insufficient.
- No unresolved rejected/ambiguous integrity interval intersects that gap.

This is evidence for continuity of that retained interval, not proof of every
physical fix or total route completeness. Open gaps, empty history, missing
boundary anchors and partial/malformed transfers remain unresolved/partial.
Valid recovered points survive independently of the proof outcome. Reconciled
gaps remain visible with their state, but no longer block edges or contribute to
unresolved count/partial quality. Route quality returns to unknown when no known
defect remains; complete is never exposed.

All recovered insertion uses the AR2B canonical engine. Chronological insertion,
dedupe, segment repair, edge replacement, distance, revision and earliest changed
predecessor commit together. Committed data alone is exposed by summaries and
route pages. Each page validates the read's captured revision in its own
transaction. A paused reader cannot retain the actor or consume recovery's time
budget through consumer backpressure. Committed route changes invalidate the
reader's next page with `E_RECORDING_ROUTE_REVISION_CHANGED`; revisions are never
mixed within one read.

Pending gaps, binding, cursor and partial points restore locally without backend
readiness. Persisted recovering state becomes deferred after restart; an old
in-memory command is never resumed. Same-principal restoration retains multiple
finished routes. Identity cleanup also deletes private recovery rows, and late
D1 callbacks/watch emissions remain fenced. All coordinates use the unchanged
backup-safe store. Recording request diagnostics omit history window timestamps;
no new coordinate/sample-key/device-identity logs or backend sync are introduced.


### AR2C-A validation evidence

Final validation passed: Core analysis clean and 234 tests; Flutter analysis has
zero errors/warnings and the same seven baseline infos; UI analysis clean and
nine tests. The full Flutter set passed as 2,058 regression tests plus three
isolated recovery benchmarks, with zero final failures/skips. The final focused
recovery/restore/migration/SDK-composition set passed 42 tests (a subset of that
full set). Android JVM tests passed 140 cases and the standalone Foundation
storage helper passed eight.

Regression command (Flutter package):

```sh
flutter test --concurrency=2 --name '^(?!.*middle D1 points through coordinator)' --reporter expanded
flutter test test/activity/activity_recording_recovery_performance_test.dart --reporter expanded
```

The benchmark file runs separately so competing native builds do not consume
its production 60 s episode deadline. A loaded intermediate sweep retained
11,988 of the expected 12,000 points when that deadline correctly stopped the
10,000 + 2,000 case. That sweep also failed two existing iOS SOS pending-command
timing assertions (`wrong_writer`, `ambiguous_native`, expected
`completed=false`, actual `completed=true`); the full regression repeat passed both without changing
SOS code. An earlier full sweep passed all 2,061 tests. These intermediate results
are not hidden as final passes or used to relax the production deadline.

Final isolated host SQLite measurements (microseconds):

| Live + recovered points | Insert + distance repair | Gap reconciliation | Recovery total | Paged read | RSS delta / ending RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1,000 + 500 | 1,333,167 | 18,219 | 1,351,386 | 8,534 | -20,414,464 / 189,677,568 B |
| 10,000 + 2,000 | 29,361,681 | 116,594 | 29,478,275 | 65,782 | 31,096,832 / 236,617,728 B |
| 100,000 + 100 | 15,566,157 | 968,975 | 16,535,132 | 3,851,078 | 86,671,360 / 324,272,128 B |

These tests use the actual coordinator/recovery/controller/SQL/route API, check
canonical counts, distance, segment merging, gap quality, every page's revision
and earliest changed predecessor. RSS is process memory observed after paging,
including GC effects; it is not peak memory. These historical measurements
predate AR2D-FIX2 localized interval repair. These are host measurements, not a
mobile performance/power or retention SLA.

Synthetic native recovery probes passed on Android API 35 emulator and iOS 26.5
arm64 simulator, both first launch and process restart. Boundary: decoded D1 →
existing backlog coordinator → recording controller/recovery → default native
SQLite → public route API. Both produced six points, one segment, a reconciled
gap, quality unknown, route revision 8, four pages and 1,221.6239499524274 m,
with matching route digests before any new restart delivery. Reverse D1/live
replay did not mutate the route. Native preparation and open DB/WAL/SHM backup
exclusion checks passed. These probes validate the final portable SQL recovery
path; subsequent foreground-trigger wiring is covered by deterministic package
tests, not claimed as native full-SDK orchestration evidence.

The universal-simulator Flutter packaging command failed on its combined
arm64/x86_64 architecture check; the bounded arm64 build and simulator probes
passed. Native backup-attribute tests required ordinary native filesystem access
to temporary files; the same helper then passed all eight cases. No unrelated
packaging/toolchain debt was changed. Disposable probes were removed and only
task-started simulators/emulators shut down. Physical TAGs/phones were untouched.

AR2B-HW1 remains **DEFERRED**, mandatory before final M6 sign-off, M6C, develop
merge or release/store distribution. The following AR2C-B section supersedes
this stage's finalization deferral. No host orchestration, History UI, backend
sync, route completeness guarantee or derived sports metrics are added.


## AR2C-B robust recording finalization

### Durable intent and cutoff

`finishActivityRecording` remains the frozen optional API. The recorder actor
validates trusted identity and known ID, normalizes time to UTC and fixes the
first cutoff. Explicit earlier cutoffs clip already committed later evidence in
the same transaction as finalizing and its private timing columns. Both
finalizing and finished retries reject a different explicit time with
`E_RECORDING_INVALID_TIME`. Equal/omitted retries retain the first cutoff.
Concurrent compatible callers share one runtime future and recovery episode.
No public models, enums, required SDK methods or ActivitySession behavior change.
Finish neither requires an active ActivitySession nor ends it; the original
session ID, activity key and session start remain on every result.

Private `finalization_started_at` and `finalization_deadline_at` store the
accepted finish time and exactly five seconds later. They are distinct from an
earlier explicit cutoff. The deadline never resets on retry/restart. Recording ID,
identity generation and recovery-generation fencing provide callback ownership;
no additional public or durable lifecycle enum is needed. Same-identity offline
restore schedules the durable intent to completion without backend readiness.
Observers may briefly receive committed finalizing state before null.

### Eligibility, budget and recovery

Only a bound, matching TAG with the existing eligible command path may start a
final transfer. An already recording-owned compatible recovery is adopted rather
than replaced; unrelated public/subsystem ownership is neither stolen nor
cancelled. Work uses durable gap/cursor boundaries through endedAt inclusively.
An older on-wire request cannot be rewritten, so adopted results are additionally
fenced by the stored cutoff. Coverage from clipped anchors is invalidated.

Finalization has a separate five-second runtime timer, armed before cutoff IO,
plus the persisted absolute deadline. Recovery does not inherit the normal 60 s
budget or the backlog timeout multiplier. An adopted episode's deadline is
shortened; a new final episode does not perform normal retries. Remaining time
is checked again after recovery-state persistence before any command starts.
Expiry cancels/fences only the recording's own lease. Restart uses the remaining
absolute window; expired/missing timing proof or now-before-start rollback gets
no wait. Rollback can retain `clockUncertain`. A runtime timer cannot be extended
by wall-clock rollback. Storage/queued actor latency is additional work, not a
claim of a five-second end-to-end mobile SLA. Route readers release their page
command/transaction before delivery, so consumer pauses cannot hold cutoff or
final commit. AR2D-FIX2 separately localizes insertion repair to affected topology.

Disconnected and busy paths do not wait for reconnection. They keep defensible
committed points, mark pending disconnect evidence unresolved and finish. Empty
history does not prove coverage. Partial transfers retain useful points and
unresolved gaps; recovery timeout adds the existing timeout issue where
appropriate and succeeds when authoritative finish storage is available.

### Commit barrier and immutable result

The final actor turn runs behind already accepted point transactions. Accepted
D1 transactions can finish even when the deadline fires during their IO. Before
committing finished it fences the owned recovery, reconciles unresolved evidence
and projects input as `unavailable` for bound records or `unbound` otherwise,
with recovery `idle`. Input unavailable is the narrow existing representation for
a recorder that no longer observes; it does not assert TAG disconnection.
Quality is partial for known unresolved defects, otherwise unknown. No route
means null distance; eligible zero-length edges may still yield zero.

Finalizing and final commits are read back after ambiguous acknowledgements;
authoritative committed intent continues and committed finished state returns in
the same call. Transient optional recovery-state/settlement storage failure gets
one conservative final transaction with `recoveryFailed`; inability to persist
or reconcile that final state remains a true typed failure. No speculative
finished summary is published. The active watcher ultimately emits null.

Finished points, binding, sample bounds, segments, gaps, distance, quality,
issues and revision remain immutable. Neither late D3 nor old D1 callbacks can
mutate them or attach old recovery to a new recording/identity. Lifecycle-only
finish does not change routeRevision; clipping, recovery and visible gap-state
changes use normal canonical route transactions. A/B/C remain independently
readable after restart and starting D. Dispose fences callbacks and closes IO
without deleting durable intent or route data.

### Validation and limits

Deterministic fake-clock coverage exercises exact inclusive microsecond live
cutoff, decoded D1 boundary filtering, normal-recovery adoption, five-second
expiry, post-write expiry, remaining restart budget, clock rollback/forward,
concurrent/equal/different finish, in-flight transaction barrier, all five crash
boundaries, ambiguous acknowledgements, transient recovery writes, identity
switch and multiple retained routes. Production SDK composition checks preserve
zero automatic phone Tracking, SOS, DMP and Protection/OTA/provisioning actions.

Native synthetic probes use byte-identical SDK runtime copies in disposable
Android/iOS consumers: decoded D3, disconnect, decoded D1, cutoff, recovery,
default native-prepared SQLite and the public known-ID route API. Each platform
creates finished A, leaves B durably finalizing after a recovered chunk, completes
B offline after abrupt process termination, then verifies both after another
restart. The driver confirms SQLite still says finalizing after termination and
before relaunch; no dispose is used for that first kill. No final route rows are directly inserted. Database/WAL/SHM privacy preparation
is checked while open. This is SDK/controller native composition evidence,
not full commercial-app orchestration or physical TAG validation.

AR2B-HW1 stays **DEFERRED**, mandatory before final M6 sign-off, M6C, develop merge
or release/distribution. Commercial app orchestration is AR3; History UI,
list/search, GPX/share, backend sync, completeness guarantees, ascent/descent and
speed/pace/calorie metrics remain unsupported.


### AR2C-B validation results

Final package regression commands (Flutter package working directory):

```sh
flutter test --concurrency=2 --name '^(?!.*middle D1 points through coordinator)(?!.*finish benchmark)' --reporter expanded
flutter test test/activity/activity_recording_recovery_performance_test.dart --reporter expanded
flutter test test/activity/activity_recording_finalization_performance_test.dart --reporter expanded
flutter test test/activity/activity_recording_migration_test.dart --reporter expanded
```

The full regression set passed 2,091 tests. The isolated normal-recovery and
finalization benchmarks passed three and seven cases respectively: 2,101 Flutter
tests total, zero failures/skips. The finalization subset passed 32 deterministic
cases. The strengthened migration rerun passed six cases, including preservation
of a non-null v3 processed-history cursor. Core analysis was clean and 234 tests
passed; Flutter analysis reported zero errors/warnings and the same seven baseline
infos with `--no-fatal-infos`. UI analysis was clean and nine tests passed.
Changed-file Dart formatting checked 15 files; `git diff --check` passed.

Android SDK JVM tests passed 140 cases with zero failures/errors/skips. Gradle's
initial direct invocation failed under default Java 26.0.1 (`What went wrong:
26.0.1`); using Android Studio's JBR passed without source changes. The standalone
Foundation storage helper passed eight cases. Android API 35 and iOS 26.5 arm64
synthetic probes each passed initial finalizing, abrupt-kill/offline restoration
and finished restart. Both preserved A at six points/revision 8/quality unknown;
B restored three committed points and finished partial at revision 5, unchanged
on the next restart. Native probes used fresh v4 databases; legacy migrations
were exercised with FFI SQLite, not claimed as native migration proof.

Earlier development runs caught obsolete finished-cutoff/finalizing-ingestion
expectations, migration projections, a gap-benchmark fixture conflict, and the
finished-A/orphaned-B observation regression. These were corrected before the
final passes. Temporary syntax errors during brace formatting were also fixed.
The first broad regression run passed 2,086 cases and failed the outdated
finalizing-ingestion expectation; the final full sweep passed all 2,091. No SOS,
DMP or unrelated baseline implementation was changed to obtain a pass.

Final host SQLite finish measurements, microseconds:

| Scenario | Persist finalizing | Recovery | Final commit interval | Total finish |
| --- | ---: | ---: | ---: | ---: |
| No route | 5,002 | 0 | 4,583 | 9,648 |
| Connected, no gap | 1,852 | 2,534 | 3,022 | 13,921 |
| Connected, recoverable gap | 1,676 | 9,875 | 3,575 | 17,397 |
| Partial recovery | 1,556 | 3,281 | 3,536 | 10,250 |
| Disconnected gap | 1,902 | 0 | 2,711 | 4,630 |
| 10,000 points, empty final history | 1,433 | 612 | 1,651 | 5,420 |
| 100,000 points, empty final history | 5,980 | 853 | 6,401 | 17,204 |

Persist-finalizing measures entry to its first acknowledged transaction. Recovery
measures command start to processed END return; the final-commit interval includes
remaining recorder settlement/queueing and final persistence. Total includes
other actor/request setup overhead, so the stage columns need not sum to total.
Measurements are representative synthetic host observations, not percentiles or
a mobile SLA. Normal recovery benchmark totals for 1k+500, 10k+2k and 100k+100
points were 1,375,901 / 33,839,339 / 16,958,011 microseconds, respectively. Expensive
middle-insertion amplification is addressed by AR2D-FIX2 interval repair. Full
100k/250k paging SQL remains accepted P3 work outside those fixes. The
paused-reader writer hold is removed by the page-scoped reader described above.

Independent correctness/Thermo review closed every confirmed finding:

| Finding | Severity | Disposition |
| --- | --- | --- |
| Adopted coverage could survive removal of its post-cutoff anchor | P1 | Invalidate clipped proof; regression passed |
| Lost cutoff/finished acknowledgement required caller retry | P2 | Read authoritative state in the same call; regressions passed |
| Transient optional recovery persistence failed finish unnecessarily | P2 | Attempt conservative authoritative partial finish; two regressions passed |
| Recovering-state IO could launch a command after deadline expiry | P2 | Recheck expiry and remaining budget after IO; fake-clock regression passed |

A separate read-only migration/evidence audit found no material findings and
verified additive migrations, retained route/cursor snapshots, native source
identity and probe artifacts. These reviews do not authorize commit, merge or
release. AR2B-HW1 remains **DEFERRED**.
