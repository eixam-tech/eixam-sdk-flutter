# Activity Recording local engine (AR2A)

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

The deterministic path is
`<ApplicationSupport>/eixam/activity_recordings/recordings.sqlite`.
This is the app's private support/files area, not Documents or external/shared
storage. Metadata contains a SHA-256 principal namespace and established
canonical user IDs, never signing hashes, credentials or authentication secrets.
The default native database factory opens lazily, enables foreign keys, WAL and
FULL synchronous commits. Identity cleanup checks for an existing file without
creating a database; path_provider registration is still required to resolve
the location during identity operations even when recording has not been used.
The public SDK disposal path closes the store without deleting it.

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

App-private placement prevents user-facing file exposure but does not exclude
OS backup. [Android Auto Backup](https://developer.android.com/identity/data/autobackup)
can include the private files directory. iOS Application Support is also backed
up unless excluded. AR2A implements neither explicit backup exclusion nor an
encrypted database or explicit iOS file-protection class. OS/device protection
inherits host defaults and has not been independently verified here. SQL cleanup
is logical deletion, not a forensic secure-erasure guarantee for free pages/WAL.

Before route data is introduced, the native/host privacy follow-up must:

- Android: exclude `eixam/activity_recordings/` in the `file` domain in legacy
  `fullBackupContent` rules and Android 12+ `dataExtractionRules`, covering both
  cloud backup and device transfer. Alternatively, an SDK-native storage bridge
  can select `Context.getNoBackupFilesDir()`. Verify actual host manifest/rules.
- iOS: set and verify
  [URLResourceValues.isExcludedFromBackup](https://developer.apple.com/documentation/foundation/urlresourcevalues/isexcludedfrombackup)
  on the recording directory before storing route data, reapplying after directory
  recreation. Cover database, WAL and SHM together and verify host file protection.

This requires deliberate native/host review; this slice does not change hosts or
falsely claim exclusion. No new public API is needed for that follow-up.

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
host metadata measurements, not mobile/route-volume or power benchmarks. Native
device builds, backup exclusion, route-volume measurement and real process-kill
durability remain later validation work.
