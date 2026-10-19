# Activity Recording local engine (AR2A + AR2B-P1)

AR2A implements SDK-private recording metadata persistence and lifecycle behind
the frozen optional `ActivityRecordingControl` contract. It is a foundation for
later route work, not full ActivityRecording production readiness. There is no
host integration, route ingestion, distance calculation, gap detection, TAG
backlog, final TAG catch-up, cloud sync or route upload.

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

## Schema version 1

| Table | Purpose |
| --- | --- |
| `recording_store_metadata` | Singleton ownership namespace and established canonical IDs |
| `recordings` | Recording ID, immutable logical session tuple, owner, optional TAG, timestamps, lifecycle, issues, counters and revision |
| `route_points` | Empty future point storage, with sample-key uniqueness, segment ID and chronological index |
| `route_gaps` | Empty future continuity records, linked to recording ID |

SQLite's `user_version` is the explicit schema version. Creation is transactional.
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
has `disconnected` input; a connected TAG has `unavailable` input until AR2B.

Finish commits `finalizing` with a frozen UTC cutoff, then commits `finished`.
The default cutoff is SDK acceptance time; explicit cutoffs cannot precede start
or be in the future. A retry cannot change a finalizing cutoff. Repeating a
retained finished ID returns its original result even if another recording is
active or has an orphaned association. It does not finish that other recording.
A process reconstructed after the first finish commit completes the persisted
finish intent, preserving cutoff and metadata. It performs no device catch-up.

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
UTC timestamps, enum/state consistency and all AR2A zero-route invariants.
Malformed ownership is a restore error, not an identity change that authorizes
deletion. There is no ordinary-access database reset. SQLite errors are sanitized
at the private boundary and no recording SQL/identity/route payload is logged.

## Empty route and interim recovery

All summary counters, `routeRevision` and `previousRouteRevision` are zero;
`routeChangedFrom`, sample timestamps and distance are null. Lifecycle/binding
changes do not increment route revision. Quality is `unknown`, recovery is
`idle`, and no timer or artificial recovering state exists.

For a known recording with empty route tables, route read emits exactly one
terminal page with its ID, revision zero, empty segments and empty gaps. An
expected-revision mismatch returns `E_RECORDING_ROUTE_REVISION_CHANGED` before
any page. Page size must be positive. Known active history recovery currently
throws `E_RECORDING_UNAVAILABLE` ("TAG history recovery is not implemented in
AR2A."). Unknown IDs return not-found; finished/finalizing recovery conflicts.
No history recovery state is fabricated.

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
SOS, DMP, Protection, OTA, provisioning, backlog and position-stream work.

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

P1 automated validation: Core analysis clean and 234 tests passed; Flutter
analysis retained seven pre-existing infos with no errors/warnings and 1,991 tests
passed; UI analysis clean and nine tests passed. The explicit AR2A/new-storage
suite plus public-export compatibility passed 85 tests (76 AR2A, eight storage,
one export). Android JVM tests passed 140 cases, including 13 new storage cases;
the standalone Foundation helper executable passed eight cases. No final test
failures or skipped tests were reported. Native tests use synthetic metadata
only, with route points/gaps zero and distance null.
