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

## Pairing list display classification

`EixamBleScanResult.pairingDisplayCategory` lets hosts filter and sort a TAG
pairing list without inspecting advertisements: show `eixam`, `legacyOrStock`
and `dfuRecovery`, drop `hidden`, and keep showing `null` (not classified, e.g.
host-built results). Resolve each poll through one `EixamPairingDisplayFilter`
per list so a device already shown does not flicker out while its name is
missing. The category is display-only: it never authorizes a connection, and
compatibility is still verified by connection and service discovery.

## TAG box-code correlation

`TagPairingCode.inspect(payload)` recognizes only `N6` or `A6` followed by six
ASCII hexadecimal characters, trims surrounding whitespace, and retains the
uppercase prefix. Recognition is structural, not manufacturing validation or
authentication. Other QR formats are unsupported; malformed recognized codes
are invalid. The SDK does not execute URLs or log the payload.

`TagPairingCodeCorrelator.find(payload, freshDiscoverySnapshot)` is a read-only
policy, not a second acquisition engine. A legacy candidate needs the exact
case-insensitive name `Meshtastic_` plus the final four code characters and SDK
Meshtastic brand semantics. Current Eixam candidates need Eixam brand semantics
plus a documented full name (`EIXAM_A6` plus six hex, or historical `N6` plus six
hex), or a canonical MAC whose final three bytes match the code. DFU and
non-connectable advertisements are not candidates. Count distinct peripheral
IDs across the complete snapshot: zero is `notFound`, multiple is `ambiguous`,
and one is only `inspectionRequired`. Never choose by RSSI or list order.

`lookup(sdk, payload)` performs one bounded fresh scan and only the necessary
read-only identity inspection. A unique current Eixam discovery result can be
confirmed by `verifyCurrentDiscovery` when its canonical MAC matches all six
code digits, or when `advertisedEixamIdentity` exactly matches `EIXAM_A6` plus
those digits. The SDK emits this evidence only from an actual structured local
name and the Eixam service in the same fresh advertisement, with Eixam brand
classification. A display/cached name or platform UUID alone remains unverified.
The UUID is only the selected peripheral's opaque transport handle. Conflicting
canonical MAC or advertised identity evidence is `identityMismatch`. Legacy
results use the existing SDK
inspection and `verifyLegacy`; no migration or acquisition API is called.

`verifyLegacy` accepts the existing migration inspection result for exactly the
selected peripheral and requires compatible hardware plus a canonical MAC
`stableIdentity` matching all six code hex digits. A verified candidate can then
enter the unchanged migration API, which revalidates eligibility and retains
same-TAG recovery ownership. `verifyCurrent` checks the selected peripheral's
connected SDK `DeviceStatus`, retaining the verified discovery evidence when
iOS has no canonical MAC. Any available runtime MAC must also match all six
digits. Another already-connected TAG is `identityMismatch`; a node ID alone is
`identityUnverified`. Normal GATT/runtime compatibility validation remains part
of the existing SDK connection flow.

Firmware docs describe `N6` plus MAC bytes 3–5; current nRF52 source advertises
`EIXAM_A6` plus those same bytes and identifies an older N6 naming error. Both
label prefixes are recognized without assuming either is a MAC/node-ID byte.
This is a 24-bit manufacturing correlation hint, never globally unique identity
or authentication. Preserve ambiguity and do not add backend lookup heuristics.

This capability does not scan, connect, pair, assign, provision, flash or persist
new bindings. Hosts must stop scanning before inspection, reject late scan
generations, verify the intended target before success/assignment, and preserve
the requested code across acquisition. Platforms exposing only a UUID and node
number, without the service-backed structured advertising identity, cannot
confirm a current TAG. Legacy last-four discovery still requires compatible
migration inspection and a matching full six-digit hardware MAC; it never uses
the current-Eixam advertising fallback.
Manual pairing behavior and the base SDK interface are unchanged.

## Firmware recovery contract

Firmware and migration sessions are SDK-owned. Hosts render `nextAction` and
call the SDK reconciliation/recovery APIs; they do not infer recovery from BLE
absence or platform error messages. `waitForDevice` preserves an uncertain or
temporarily unavailable device. `recover` and `retryRemoteRecovery` identify a
supported remote opportunity. `physicalRecovery` / `physicalRecoveryRequired`
represent the manual recovery verdict.

`retireDeviceMigration(sessionId)` releases a quiescent migration and its firmware
ownership after archiving the original SDK record, including identity and firmware
evidence. It rejects running operations and never cancels a transfer or changes the
TAG. Hosts use it when choosing another TAG; route dismissal alone does not retire
recovery. A completed migration remains durable across restart until the host has
paired the verified TAG and retires the completed handoff record.

For an interrupted transfer, manual recovery requires durable evidence that
native transfer engaged, the correct supported recovery endpoint was strongly
matched, a native remote recovery invocation actually ran and failed terminally,
bounded recovery opportunities were exhausted, and the expected application
did not return. GATT 133 is a transport failure; it is not proof of invalid
firmware. Absence without that evidence remains waiting. An independent
authoritative platform verdict for the same device can also establish that an
invalid application has no supported remote recovery capability.

The SDK never retries or cancels a native legacy DFU after it started and never
starts a DFU on its own, including on app relaunch: `attemptRecovery` only
refreshes evidence, and `recoverFirmwareUpdate` fails with the typed
`remoteRecoveryUnsupported`. The Nordic Android service answers an abort with
Reset (Op Code 6), and a bootloader holding an erased application then reboots
into USB/UF2-only mode, so Android uses `setNumberOfRetries(0)`, watchdogs fail
only the Dart session, and plugin detach / task removal do not stop the service.
Exhaustion survives process death. Interrupted-update recovery is the explicit,
user-started `DfuRecoveryControl` below.

After physical recovery, the SDK verifies the same hardware and actual
application/version. A returned target completes only after verification; a
valid old application returns a safe transfer retry; a recovered stock source
returns `continueMigration`. A different hardware identity cannot complete the
session. Hosts keep showing the SDK-directed journey until that verdict changes.

Cable recovery installs the EIXAM firmware UF2 directly. Once a cable recovery is
in progress (`prepareCableRecovery` done or `physicalRecoveryRequired`), a TAG that
comes back running EIXAM firmware ends the interruption through `DfuRecoveryControl`:
a connected TAG with a readable application version (any version) becomes
`recovered`; an advertising EIXAM TAG that is not connected yet clears the record
with `physicalRecoveryCompleted`. Neither is a version mismatch nor an update
offer; an older version only shows the normal update card later.

A restored or re-checked migration or OTA never starts by itself. `reconcileDeviceMigration`
(with or without `attemptRecovery`) only observes and returns `continueMigration`;
the transfer starts only through a new `migrateDeviceToEixam(...,
interruptionWarningAcknowledged: true)` / `startFirmwareUpdate` call, which re-runs
the pre-flight checks.

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

## Interrupted DFU recovery (`DfuRecoveryControl`)

Optional capability (`sdk is DfuRecoveryControl`; the base interface is unchanged).
**BLE resume is not possible with bootloader 0.4.3; recovery is by cable.** After
an interrupted legacy DFU the bootloader answers every new Start with
INVALID_STATE and the Nordic library then resets it into USB/UF2-only mode
(verified on hardware, Start then Reset 108-245 ms later). Nothing here starts a
DFU automatically.

```dart
if (sdk is DfuRecoveryControl) {
  final status = await sdk.getDfuRecoveryStatus();
  sdk.watchDfuRecovery().listen(render); // scans only while an interrupted update is persisted
  switch (status.availableAction) {
    case DfuRecoveryAction.prepareCableRecovery:
      await sdk.prepareCableRecovery();     // one tap
    case DfuRecoveryAction.restartDfuFromScratch:
      await sdk.restartDfuFromScratch();    // one tap
    case DfuRecoveryAction.forgetDevice:    // iOS; after the user forgot the TAG
      await sdk.confirmDeviceForgotten();
    case DfuRecoveryAction.none:
      break;
  }
  await sdk.dismissDfuRecovery();
}
```

`DfuRecoveryStatus`: `state` (`resumable` = interrupted update with the bootloader
visible (E1; the name is historical, it cannot resume), `iosStaleLink`,
`silentNeedsCable`, `recovered`, `unknown`), `reason` (`DfuRecoveryReason`),
`availableAction`, `needsCable`, `progressFraction`, `deviceId`, `warnings`. No
localized text.

- E1 action by bootloader version: `resolveE1RecoveryStrategy(version)` returns
  `cableRecovery` for 0.4.3 and for any unknown version and
  `restartFromScratch` only for versions in `kBleRestartCapableBootloaderVersions`
  (EMPTY today; add a version only with hardware proof). Only the resolved action is
  offered; the other is refused with `actionNotAvailable`. The SDK can read the
  bootloader version without extra protocol: the bootloader exposes the Device
  Information Service firmware revision (`2A26`, for example `0.4.3 s140 6.1.1`) while
  advertising as AdaDFU; the controller's `bootloaderVersionReader` hook reads it
  and is consulted only when the allowlist is not empty. The final E1 product
  behaviour is an open product decision.
- `prepareCableRecovery()`: expected outcome is the bootloader reset into USB/UF2
  mode. After it, the TAG being gone from the air gives `silentNeedsCable`. The
  phone cannot see the UF2 drive.
  `silentNeedsCable` is also derived from a persisted interrupted update plus
  silence for `EixamDfuRecoveryConfig.silenceWindow`.
- `restartDfuFromScratch()`: a fresh DFU session for a bootloader proven to allow it.
  Both actions use the same fresh-session mechanism; neither is retried.
- `recovered` only after the TAG reconnected and the installed version was verified
  by the existing reconciliation, never from DFU progress alone.
- After a cable recovery the TAG reappears as stock Meshtastic. A fresh
  re-verification (hardware model 105, same identity) supersedes the stale
  interrupted record, so the stock to EIXAM migration is no longer blocked by
  `firmwareUpdateResumeRequired`. Ambiguous identity or hardware stays fail-closed.
- iOS stale link (`iosStaleLink`, action `forgetDevice`) is derived from CBError 14
  on a connect while the TAG advertises. UNVERIFIED ON HARDWARE.

### Pre-flight and acknowledgement (every OTA, migration and recovery start)

Each check is pass, warning or fail. **A value that cannot be read never blocks**; it
is returned as a typed `DfuPreflightWarning` on `FirmwareUpdateSession.preflightWarnings`,
`FirmwareUpdateEligibility.warnings` and `DfuRecoveryStatus.warnings`. Only a value
that was read and fails its threshold, or a precondition known to be false, blocks
with a `DfuPreflightFailure` (`FirmwareUpdateException.code == failure.name`).

| Check | Fails when | Unknown (warning) |
| --- | --- | --- |
| Bluetooth adapter | powered off (`bluetoothOff`) | `bluetoothStateUnknown` |
| App foreground | not resumed (`appNotForeground`) | `appForegroundUnknown` |
| Screen on | off (`screenNotAwake`) | `screenStateUnknown` |
| Phone battery | read below 30 % (10 % while charging) (`phoneBatteryLow`) | `phoneBatteryUnknown`; charging state unreadable: `phoneChargingUnknown` and the lenient threshold |
| TAG battery | read below the policy minimum (`deviceBatteryLow`) | `deviceBatteryUnknown` (stock firmware, bootloader) |
| TAG visible, no other owner | recovery actions only (`deviceNotVisible`, `operationInProgress`) | - |

Thresholds are inclusive pass at the limit (30 passes, 29 fails). Platform notes:
TAG battery is unreadable on stock Meshtastic and in the bootloader on both
platforms; phone battery and charging are read natively (Android
`ACTION_BATTERY_CHANGED`, iOS `UIDevice`) and can be null; screen state is
`PowerManager.isInteractive` on Android and "app active" on iOS. Keeping the screen
awake during the transfer (wakelock) is the host's job; the SDK only refuses to start
while the screen is off.

Starting requires the host to have shown "if the update is interrupted, a computer
will be needed": `FirmwareUpdatePolicy(interruptionWarningAcknowledged: true)` for
`startFirmwareUpdate` and `migrateDeviceToEixam(candidate:, interruptionWarningAcknowledged: true)`.
Without it nothing starts (`interruptionWarningNotAcknowledged`). Breaking for
hosts: existing start calls must pass it.

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

## Optional TAG alerts (foundation)

`TagAlertsControl` is an optional capability: detect it with a type check
(`sdk is TagAlertsControl`). Existing `EixamConnectSdk` implementations need no
change. This block ships only the shared foundation: per-TAG settings, the
notification port and the default local-notification adapter. **It contains no
battery source and no disconnect policy**, so the SDK does not emit TAG alerts
by itself yet.

TAG alerts are local notifications generated on the phone. They are a
convenience, **not a guaranteed safety feature**: the OS may delay, coalesce or
drop notifications, and they never replace or interact with SOS flows. They do
not use the SOS channel, payloads or colors.

```dart
final sdk = await EixamConnectSdk.bootstrap(EixamBootstrapConfig(
  // ...
  tagAlertNotifier: myNotifier,        // optional: replaces the default adapter
  tagAlertTextResolver: (alert) => ..., // optional: localized text, default adapter only
));
if (sdk is TagAlertsControl) {
  final key = tagAlertDeviceKey(deviceStatus); // canonical hardware id (Android MAC), else deviceId (iOS UUID); never the node id
  final settings = await sdk.getTagAlertSettings(key);
  await sdk.updateTagAlertSettings(settings.copyWith(disconnectAfter: const Duration(minutes: 15)));
}
```

- `TagAlertSettings { deviceId, batteryAlerts = true, disconnectAfter = 5 min }`
  is immutable and validated. `disconnectAfter` is `null` (never) or 5, 15, 30
  or 60 minutes; anything else throws `ArgumentError`. JSON is versioned
  (`v: 1`); unknown versions and out-of-set values throw `FormatException`.
- `getTagAlertSettings` returns defaults when nothing is stored **or** the store
  is unreadable. Unreadable data is reported as a `TagAlertsException`
  (`E_TAG_ALERTS_RESTORE_FAILED`) on `watchTagAlertSettings`, which stays usable;
  the next successful update replaces the bad data. `updateTagAlertSettings`
  throws `TagAlertsException` (`E_TAG_ALERTS_SESSION_REQUIRED`,
  `E_TAG_ALERTS_PERSISTENCE_FAILED`, `E_TAG_ALERTS_UNAVAILABLE`).
- **The key is stable for a TAG**: `tagAlertDeviceKey(status)` is the canonical
  hardware id when present, otherwise the transport device id. It never uses the
  firmware node id, which can arrive after the pair-time `0x23` timeout and
  would otherwise change the key (and strand the TAG's settings) mid-session on
  iOS. A completed device migration re-keys the settings, cycle and alerts
  explicitly.
- Settings live under `eixam.tag_alerts.v1`, per identity scope and per device.
  They are removed, together with every scheduled and delivered TAG alert, on
  `clearSession`, `clearLocalUserData`, and when the signed user, app or backend
  changes (including the bootstrap path that clears a session restored for
  another app id). `unpairDevice` removes that device's settings and alerts.
  `dispose` releases resources but intentionally keeps persisted settings and
  scheduled alerts.
  A cold-start session restore that *throws* (for example a locked keychain)
  is not treated as "signed out": settings and scheduled alerts are kept, and
  the stored owner scope decides once the identity is known. Only a restore
  that completes with no session, or an explicit logout, wipes.
- `TagAlert { kind, deviceId, deviceAlias?, batteryThreshold?, elapsed?,
  lastTagPosition? }` carries data only. `batteryThreshold` is
  `below30 | below10`, derived from the TAG's existing 2-bit battery level; the
  SDK never presents an exact percentage. `lastTagPosition` accepts only
  `SdkLocationSource.connectedDevice`; phone, cached and backend positions are
  rejected. Wording comes from a `TagAlertTextResolver` (neutral English by
  default; coordinates are not included in default text).
- `getTagAlertPermissionState()` never prompts. `requestTagAlertPermission()`
  prompts only when the host calls it; the SDK never calls it at bootstrap.
  States: `granted | denied | permanentlyDenied | notDetermined | unsupported`.
  On Android the passive state is `granted`/`denied`; `permanentlyDenied` is
  only reported by `requestTagAlertPermission()`.

### Low-battery alerts (F1)

When `batteryAlerts` is on (the default) and the host has notification
permission, the SDK shows a `TagAlertKind.batteryLow` alert through the
`TagAlertNotifier` when the TAG's battery drops below 30 % or below 10 %. Alerts
use only the TAG's own 2-bit battery level (or a live `0x23` percentage mapped to
the same bands); the SDK never presents an exact percentage.

- Bands: `ok` (>= 60 %), `medium` (30-59 %), `below30` (10-29 %), `below10` (< 10 %).
- **Confirmation:** a band counts after two consecutive live readings from
  distinct samples within one connection. A single stray reading never fires or
  rearms anything. Confirmation never spans a disconnect.
- **Like a phone:** each downward crossing alerts again after the battery was
  confirmed above the threshold. `below30` fires if it has not fired since the
  last confirmed `medium`/`ok`; `below10` fires if it has not fired since the
  last confirmed `below30`/`medium`/`ok`, and also marks `below30`, so a direct
  fall from >= 30 % to < 10 % gives one alert (10 %).
- The delivered alert is removed only when `ok` (>= 60 %) is confirmed.
- With `batteryAlerts` off the cycle keeps being tracked but nothing is shown or
  marked; turning it back on while low alerts after two live readings.
- The already-alerted state is persisted per device (same `eixam.tag_alerts.v1`
  blob), so restarts and reconnects do not repeat an alert.
- **Live data only.** Readings come from `0xD3` live batches (newest sample,
  device timestamp within 2 min ahead of receipt and `max(3 min, 1.5 x the TEL
  interval)` behind it, capped at 30 min; the interval is learned from the last
  `0x23` reply; without a plausible timestamp there is no reading), classic
  12-byte TEL of the connected TAG, and `0x23 GET_DEVICE_STATUS` replies (a
  percentage of 0 or `0xFF` is ignored). Every device-scoped reading must come
  from the device the current status describes (`event.deviceId ==
  status.deviceId`; a known `nodeId` must match too). Backlog (`0xD1`), neighbor
  relays (`0xD2`), SOS packets and any stored `DeviceStatus` are never readings.
  The freshness window is provisional and needs physical tuning.
- **Delivery is at-least-once.** The alert is shown first and the "already
  alerted" mark is persisted afterwards. If it cannot be shown (notifier error,
  5 s timeout, plugin not yet initialised under host-managed notifications) it
  is not marked and the next confirmed reading retries; a failed write after a
  successful show may repeat the alert, never lose it. While notification
  permission is denied, permanently denied or not asked yet, the threshold is
  not marked, so granting permission later while still low alerts on the next
  live reading. (The permission check uses the OS notification permission even
  when the host supplies its own notifier.)
- **SOS.** Battery alerts continue during an SOS; they use their own channel and
  never touch SOS UI, ids or flows. (The planned disconnect alert will be
  suppressed during SOS.)
- **On connect and on foreground resume** the SDK uses `0x23` once. The resume
  probe runs at most once per 10 minutes per device, only after a real return
  from the background, and only **after SOS rehydration has completed** (if SOS
  state cannot be confirmed within 10 s it stays silent). The gate (SOS,
  pre-SOS, firmware update, provisioning, device migration) is checked after
  that wait and again immediately before the send. It sends only when the
  command path is **already** ready (`hasCommandCapableBleRuntime`, or the native
  owner reports ready); otherwise it does nothing. It never goes through the
  generic runtime-status helper, so it can never start a reconnect, a rebind or a
  rediscovery. There is no polling and no new command.
- **Limits, by design.** Alerts work while the app receives live TAG data. A
  stationary TAG sends no `0xD3`, so no new reading arrives; a backgrounded app
  receives nothing from the TAG (native Protection Mode does not forward battery
  data to Dart); an alert can therefore be late or never come. This is not a
  guaranteed safety feature and does not replace checking the device.

### Disconnected TAG alerts (F2)

When `disconnectAfter` is not "never" (default 5 minutes) and notification
permission is granted, the SDK raises a `TagAlertKind.tagDisconnected` alert if
the TAG link stays down for more than that long, and `TagAlertKind.bluetoothOff`
if the phone's Bluetooth is off. A disconnect alone is not an incident: the TAG
keeps working offline and resyncs on reconnect.

- **Dead-man lease while connected.** A local notification stays scheduled at
  `lastPush + X + slack` and is pushed forward at most every
  `clamp(X / 4, 60 s, 10 min)`, which is also the slack. If the app can no longer
  observe the link, it fires between X and 1.25 X after the last contact. A
  reconnect removes it, pending or already delivered.
- **Observed drop.** When this run of the app sees an unexpected drop, the alert
  is rescheduled to exactly `drop + X`.
- **Never alerts for:** a manual disconnect or unpair; a deliberate flow
  (firmware update, device migration, the provisioning reboot window), where the
  deadline moves to the end of the hold; an SOS in progress (cancelled, and
  re-armed when it ends); the "never" setting; missing notification permission
  (denied, permanently denied or not asked yet); a TAG that was already away
  when the app started (no honest start time, and an alert scheduled by an
  earlier run is left alone).
- **Liveness signal.** The firmware sends no BLE keepalive, so a stationary TAG
  produces no traffic. The signal is the OS connection state staying "connected"
  (passive; no extra BLE traffic and no RSSI reads), re-asserted every 30 s while
  the app runs. Position data is not needed to prove liveness.
- **Content.** The alert carries the last position the TAG itself reported (never
  the phone's) with its timestamp; the default text omits coordinates.
- **Background (iOS and Android).** The lease is the periodic push, and a
  suspended or Doze-stalled app cannot keep pushing it while the link is fine,
  which would raise a false alert. So **only the lease** is dropped when the app
  goes to the background (and re-armed on resume); an app relaunched in the
  background never arms it. **Arm-at-disconnect is not affected**: if Dart
  observes an unexpected drop while backgrounded it still schedules the alert at
  `drop + X` (and `bluetoothOff` likewise), with every usual suppression (SOS,
  manual, firmware update, provisioning reboot, migration, "never", permission).
  A backgrounded app with a connected TAG and no events schedules nothing.
  A drop observed in the background is scheduled **without waiting on anything
  else** (the iOS wake window is about 10 s): it uses the last known
  notification-permission state (unknown counts as allowed; scheduling while
  permission is really missing is harmless, the OS drops it) and defers cleanup
  retries until after the schedule. The permission answer is refreshed
  afterwards without blocking, and the alert is re-evaluated if it changed.
- **How a background drop reaches Dart.** iOS with `bluetooth-central`: the
  central manager that owns the connection (the native Protection bridge when
  armed, otherwise flutter_blue_plus) is woken on `didDisconnectPeripheral`; the
  Flutter engine of the woken process runs the handler (about 10 s). The native
  bridge's event sink has no buffer, so an event with no engine attached is
  lost, and after a system kill only the native bridge is relaunched by state
  restoration. Android with Protection Mode: the GATT callback runs in the
  process without Dart; the event is buffered and replayed (with its native
  timestamp, which becomes the drop time) when an engine attaches, so with the
  task removed the alert waits until the app starts again. Both are
  documented-behavior assumptions that need device validation.
- **Debug logs.** In debug and profile builds (never release) the SDK prints `[TAG_LEASE]` lines (link
  state with lifecycle, drop cause, schedule/cancel with kind and fire time, and
  `dropToScheduleMs`, the time from the observed drop to the schedule being done).
  They contain no device ids (a short digest `key#xxxxxx` instead), aliases or
  coordinates.
- **Cost.** A push is one platform call (the notifier caches the slot id), runs
  inside the controller's serialized tail with the 5 s bound and cleanup retry,
  and newer link snapshots replace older queued ones.
- **Device migration.** A re-key cancels the old key's alerts and the lease is
  re-armed under the new key.
- **Limits.** Without a running Dart isolate nothing observes the link: a
  suspended iOS app is not woken for an idle TAG, and Android behavior in Doze is
  unverified. A native arm-at-disconnect (iOS `didDisconnectPeripheral`, Android
  GATT callback, scheduling its own notification with the same reserved id
  scheme, `tag_alert:` payload and channel) can be added later without any
  public API change; it needs device validation. This is not a guaranteed safety
  feature.

### Known issues and residual risks

- **Stale `nodeId` after re-pairing a different TAG (pre-existing, not changed
  here).** `ble_device_runtime_provider.dart:449`, `:644` and `:1303` use
  `nodeId: runtimeStatus?.nodeId` and `DeviceStatus.copyWith` keeps the old
  value when it is null, so if the pair-time `0x23` misses (2 s timeout,
  `:1484`) a newly paired TAG can carry the previous TAG's node id until the next
  reply. This also affects the country-config key. TAG alerts are protected by
  the device-id check and by not using the node id in the key; switching TAGs is
  rare. Pick it up separately.
- A TAG without a battery (or reading 0) cannot be told apart from an empty one
  on the 2-bit TEL path; two-reading confirmation is the only guard.
- A redelivered older `0xD3` batch inside the freshness window can count as a
  reading.
- The settings and cycle key is `tagAlertDeviceKey(status)`; a host that stores
  settings under another id will not have its unpair cleanup applied.
- Notification permission is read from the OS even when a host notifier is
  supplied.

### Notification delivery (`TagAlertNotifier`)

`show`, `schedule(alert, at)`, `cancel(deviceId, kind)`,
`cancelAllForDevice(deviceId)` and `cancelAll()`. `(deviceId, kind)` is one slot:
scheduling again replaces the pending alert (cheap enough to push a reminder
forward repeatedly), and an `at` that already passed is delivered immediately.
`cancel*` also remove already delivered alerts, because they show the TAG alias.
Hosts may inject their own notifier through `EixamBootstrapConfig.tagAlertNotifier`.

The default adapter:

- uses channel `eixam_tag_alerts` (high importance, not max) and payload
  `tag_alert:<kind>:<hex(device key)>`. The key is hex-encoded so no device id
  can produce the substring `sos`, which hosts use to classify SOS
  notifications. TAG alert taps are ignored by the SDK's SOS/BLE navigation;
- never calls `initialize` on the shared `flutter_local_notifications` plugin.
  With `EixamNotificationPolicy.sdkManaged` it asks the SDK notification adapter
  to initialize before showing or scheduling; with `hostAppManaged` the host must
  already have initialized the plugin (or inject its own notifier);
- schedules with `AndroidScheduleMode.inexactAllowWhileIdle` (no exact-alarm
  permission), so delivery time is approximate;
- relies on the plugin's native persistence and boot receiver. It stores no
  schedule of its own.

**Reserved notification ids.** `flutter_local_notifications` is a process-wide
singleton and its ids share one namespace with Android native notifications. TAG
alerts use only ids `1000000000..1000099999`, derived from a stable hash of
(device key, kind) and probed on collision against pending and delivered
notifications. Known ids in use: `6021-6024`, `6031` (Android services), `41001-41002`
(DMP), `42001-42008` (SDK SOS mirror in the commercial app), `43000` (nearby text)
and `44001` (activity). The SDK's generic id generator now skips the reserved range.

### Host requirements

- **Core library desugaring** must be enabled in the host's Android Gradle
  build (`isCoreLibraryDesugaringEnabled = true` and
  `coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:<version>")`),
  as required by `flutter_local_notifications` for scheduled notifications.
- **Time zone data:** the default adapter schedules absolute instants in UTC and
  needs no time zone initialization. The host owns `tz.initializeTimeZones()` /
  `tz.setLocalLocation(...)` if it uses `tz.local` elsewhere (the commercial app
  already does); the SDK never initializes them.
- **Android manifest:** the SDK manifest declares `RECEIVE_BOOT_COMPLETED`,
  `ScheduledNotificationReceiver` and `ScheduledNotificationBootReceiver` (with
  the standard `BOOT_COMPLETED`, `MY_PACKAGE_REPLACED` and QUICKBOOT intent
  filters), so hosts that do not declare them still get delivery and reboot
  rescheduling. Identical host declarations merge without conflict. Action
  buttons additionally need `ActionBroadcastReceiver`, which TAG alerts do not use.
- **iOS:** request permission with `requestTagAlertPermission()` at a moment the
  user understands; no Info.plist background mode is added by this capability.

## Optional activity recording (AR2A + AR2B + AR2C-A + AR2C-B + AR2D fixes)

AR1 exports `ActivityRecordingControl`, immutable recording/route models, state
enums and `ActivityRecordingException` from `eixam_connect_core`, also re-exported
through the Flutter package's public entrypoint. Production SDK instances now
implement the optional capability's local, durable recording lifecycle: start,
immutable verified TAG binding, committed observation, known-ID retrieval,
finish, same-identity restoration and multiple finished-record retention.
AR1's public contract remains unchanged.

AR2B-P1 prepares recording storage through a private native bridge before SQLite
opens: Android uses the SDK subtree under `Context.noBackupFilesDir`; iOS keeps
Application Support and sets/verifies directory backup exclusion. Android's
legacy AR2A directory migrates whole before destination use. Preparation and
migration failures fail closed using existing errors. Consumers need no custom
backup rules or native configuration. This adds no public API or ingestion.

AR2B ingests eligible live D3 TAG positions through a private decoded delivery
path before public transport dedupe. Recording dedupe is durable and transactional;
public batch events keep their existing dedupe behavior. The recorder enforces
immutable bound TAG identity, genuine sample UTC/window/geographic validation,
canonical chronological ordering, continuity segments and conservative live
integrity gaps. Phone/backend locations and timestamp-less Classic TEL are never
route sources.

Recorded horizontal distance uses Haversine (radius 6,371,000 m) across eligible
adjacent edges only, excluding altitude, gaps and ambiguous ordering. No eligible
edge means null; a genuine zero-length edge permits 0.0. Route points, topology,
summary, metrics and revisions commit atomically; watchers publish committed
summaries without route arrays. Production ingestion, recovery and finalization
implement the frozen optional capability. Consistent paged route reads support
revision checks, segment continuations and suffix replacement.

Out-of-order/recovered insertion repairs affected canonical neighbours and
topology intervals until persisted continuity stabilizes. Unchanged downstream
segments are retained; genuine gap/segment changes may require broader repair.
This changes internal work only, preserving distance, ordering, dedupe, gap
semantics, revision and earliest changed suffix behavior. It introduces no timing
guarantee or public paging change.

Persisted route identifiers, recovery cursors and gap boundaries are validated
before use. Inconsistent numeric/text gap bounds fail before overlap filtering,
so corrupted gaps cannot silently disappear from suffix reads. Malformed stored
facts fail closed through existing sanitized restore/persistence errors; they do
not trigger automatic repair, deletion or reset. Identity scoping and local
evidence preservation remain in force. No public contract or schema change is
introduced.

Before Finish clips points/gaps or aggregates route facts, it validates every
persisted point, including the post-cutoff tail, using the canonical point rules
in bounded-memory batches in the same transaction. Resumed finalizing intents
validate again while preserving their cutoff and deadline. Integrity/query
failure preserves evidence and publishes no speculative clipped/finished state;
unchanged corrupt storage keeps failing on retry. No automatic repair occurs.

Routes and finished results restore locally/offline. AR2C-A adds confirmed TAG
disconnect gaps, bounded D1 recovery through the existing backlog coordinator,
chronological live/recovered durable dedupe and conservative gap reconciliation.
Recovery triggers coalesce, with up to three attempts (1 s/5 s retry delays) in a
60 s episode; unavailable command ownership defers without displacing any owner.
A complete validated retained transfer must durably span both closed gap
boundaries without rejected/conflicting evidence. Empty history or one interior
point does not heal a gap. Recovery uses existing idle/recovering/deferred states;
known unresolved defects remain partial, otherwise quality remains unknown.
Matching input can be observing; this means attachment, never fresh GPS.

AR2C-B implements durable bounded finalization. The first accepted finish fixes
an inclusive UTC cutoff before final catch-up; all later D3/D1 points must be at
or before it. An eligible recording-owned recovery gets at most five seconds
of total finalization budget, including any existing recovery. Disconnected or
busy paths finish promptly with committed evidence. Partial history and recovery
timeout can produce a successful immutable partial result. Finish does not
require the logical ActivitySession to remain active and never ends it.

Complete-route guarantees, ascent/descent, speed/pace/calories, backend
sync and host UI integration remain unimplemented. Commercial integration belongs
to AR3. The sections below preserve the frozen public contract. See
[local engine implementation](../../docs/ACTIVITY_RECORDING_LOCAL_ENGINE.md)
for storage, privacy, lifecycle, route semantics and verification limits.
Physical live-D3 admission remains explicitly deferred under
`AR2B-HW1 — REAL TAG D3 ACCEPTANCE`; that gate must pass before final M6 sign-off,
M6C, merge to develop or release/store distribution. Automated and native
synthetic acceptance permits continued SDK development without claiming physical
route acceptance.

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

#### Recording source identity kinds

The existing `deviceIdentity` String supports two disjoint Recording-specific
source kinds; public method signatures and result shapes are unchanged:

- Legacy canonical hardware MAC, such as `AA:BB:CC:DD:EE:01`. Existing input
  normalization and persisted bindings remain supported.
- Registered node, encoded exactly as `node:<decimal>`, for example `node:42`.
  The decimal domain is `1..4294967294`: unsigned 32-bit node IDs excluding
  unset zero and broadcast `0xffffffff`. Signs, leading zeroes, whitespace,
  hexadecimal, alternate encodings and unknown namespaces are rejected.

Node Start/Bind checks the current paired device's node and provisioned status,
then reads its existing assignment using `RegisteredDeviceAssignmentVerifier`.
The device and authenticated owner generation are checked again after that read.
Recording verification never creates/claims an assignment, provisions a device,
or chooses/connects another peer. A failed registry read reports sanitized
`E_RECORDING_DEVICE_UNREADABLE`; missing assignment or mismatched source reports
`E_RECORDING_DEVICE_MISMATCH`. Same-binding retries remain idempotent without a
new device read; another binding cannot replace the existing source.

Provisioning comes from the SDK's existing device-status state. Recording does
not perform a fresh status command or claim that cached state is fresh. A host
requiring a connected TAG at new Activity Start owns that fresh-status preflight
and its saved preferred-peer/registered-node selection. This commercial policy
is not imposed on generic SDK Session or unbound Recording callers.

For node-bound D3, the current device must be connected, paired and provisioned,
and every decoded packet node must equal both the current node and immutable
binding. No canonical hardware MAC is required; an iOS peripheral UUID remains
only the transport/reconnect reference. D1 uses the same bound/current node and
provisioning checks, verifies each chunk node, and preserves transfer session,
connection/account generation, command ownership and commit-before-ACK rules.
META/END remain subject to that eligible source and existing transfer ownership.
Only the private Recording adapter stamps node identities; public position-batch
identities and normalization remain unchanged.

Disconnect preserves Session, Recording and binding, marks input unavailable,
and defers recovery. The same provisioned node may resume D3 and eligible D1 on
normal reconnect without recreating the Recording or resetting its route.
SQLite accepts both identity kinds without rewriting legacy records or changing
schema; malformed/unknown stored identities fail closed. Older MAC-only SDK
builds cannot restore node-bound records and fail closed rather than reinterpret
them. Generic unbound
Recording still accepts no route input until explicitly bound. These are
operational source identities, not hardware attestation. Global
`DeviceStatus.canonicalHardwareId` and its normalizer are unchanged.

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
another active recording. An explicit different cutoff on a finalizing or
finished ID throws `E_RECORDING_INVALID_TIME`; omitted or equal UTC cutoffs are
idempotent. Concurrent compatible calls coalesce. Missing IDs produce
`E_RECORDING_NOT_FOUND`. Finished records project recovery as `idle` and input as
`unavailable` when bound, otherwise `unbound`; route quality and issues preserve
outcomes without claiming active observation. A lifecycle-only finish does not
increment routeRevision. Known-ID route reads remain available after restart.

`getActivityRecording(recordingId: ...)` retrieves a known active/finalizing or
retained finished result for finish idempotence, navigation, immediate summary
or crash recovery. It returns null only for confirmed absence within the current
identity, not a storage failure. There is no latest-only result assumption.
Finished history browsing is exposed by the separate optional capability below.
The SDK provides no History UI or search API.

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
Each finite read captures one local route revision in its first successful page
transaction after listening starts. Every later page atomically validates that
revision and reads its data in a separate transaction. A committed route mutation
between pages terminates the stream with `E_RECORDING_ROUTE_REVISION_CHANGED`
before delivering any page from the new revision. Metadata-only changes and
ignored duplicate samples do not invalidate a read whose revision is unchanged.
Consumers refresh recording state and start a new read after that error; pages
from a failed read are not a completed route or suffix replacement.

Each page's recorder command and SQLite transaction finish before delivery.
Pausing a subscription retains no writer ownership, database transaction, native
cursor or historical snapshot, so live writes, recovery and Finish continue
without consumer resume/cancellation. No pause timeout or reader admission limit
is introduced. Cancellation prevents further page commands and suppresses pending
delivery; identity replacement and SDK disposal fence readers without awaiting
paused event delivery. An already executing page operation may finish draining.
An empty route still emits a terminal page. A nonpositive page size is invalid;
page size bounds points per page.

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

## Optional local finished ActivityRecording history (HISTORY-P1)

Discover `sdk is ActivityRecordingHistoryControl`, independently of
`ActivityRecordingControl`. Existing generic SDK and recording implementers need
no new methods. Both the capability and `SdkActivityRecordingHistoryPage` are
exported through core and the Flutter public entrypoint.

`listFinishedActivityRecordings(limit: 20, cursor: ...)` returns an immutable list
of existing `SdkActivityRecording` summaries and an opaque nullable `nextCursor`.
`hasMore` is derived from that cursor. Limits are 1 through 100 inclusive;
out-of-range values throw `RangeError`, rather than being clamped. Empty and
terminal pages have no next cursor. There is no total-count query or live watcher.

Only committed `finished` recordings appear. Active/finalizing results stay on
the existing active observation path. A successfully finished partial route,
unresolved gaps, issues, unknown quality and nullable distance remain valid,
unchanged history facts. Null distance does not mean zero; neither unknown nor
partial quality proves completeness or failure.

Ordering is fixed Recording `endedAt` descending at exact integer microsecond
precision, then `recordingId` descending with binary comparison. It does not use
finalization commit time, route revision or raw ISO text ordering. Logical
`activitySessionStartedAt` and `recordingStartedAt` retain their distinct meanings;
`endedAt` remains the Recording cutoff, not the ActivitySession's end timestamp.

Pass the returned cursor unchanged; do not construct, decode or persist a second
history index in the host. Tokens are versioned and owner scoped. Malformed,
unsupported or foreign tokens fail with sanitized `E_RECORDING_INVALID_CURSOR`.
The cursor is not authorization: queries independently require the trusted current
Recording owner. Signing rotation preserves same-principal history and cursor
scope; account/app/backend replacement, canonical conflicts and logout follow the
existing Recording purge/quarantine rules. Pending results are generation fenced.

Continuation reads strictly below the last delivered `(endedAt, recordingId)`.
Pagination is not a snapshot across requests. A newer head insertion does not
shift or duplicate older results; refresh page one to see it. A delayed finish
with an older cutoff below the cursor may appear on a subsequent page. Hosts may
refresh after finish, summary dismissal or return to their activity screen. No
polling is required.

History reads summary/order metadata only. It loads no route points, gaps,
recovery bookkeeping or geometry, recalculates no distance, and performs no active
restoration, recovery, finalization or session/safety lifecycle operations.
Known-ID detail remains `getActivityRecording`; route data remains
`readActivityRecordingRoute`. Listing certifies readable summary/order metadata,
not route integrity: corruption confined to route storage is checked by the
existing detail/route paths. Encountered invalid summaries/order entries fail the
whole page with `E_RECORDING_RESTORE_FAILED`, without skipping, defaults, deletion
or silent repair. The initial metadata integrity audit checks index completeness;
its prepared state is cached under the single-writer and owner identity boundary.

Private schema version 5 adds only ordering keys in `recording_history_order`
inside the same no-backup Recording database. Forward migration validates and
backfills in bounded metadata batches, without rewriting existing summary rows
or changing route schema. Finished transitions and ordering entries commit in the
same transaction. Initial migration/integrity preparation may be linear in stored
summary count; ordinary pages use bounded indexed seeks and summary primary-key
lookups. The integer index supports the existing SQLite platform floor without
expression indexes or floating-point datetime conversion.

History remains installation-local. There is no backend endpoint, upload, cloud
or cross-device synchronization, age limit or pruning.
Long-term storage growth remains a deferred policy concern. Firmware, phone GPS,
SOS, DMP, Tracking and Protection ownership are unrelated and unchanged.

### Optional local finished Recording deletion

Feature-detect `sdk is ActivityRecordingDeleteControl`, then call
`deleteFinishedActivityRecording(recordingId: id)`. This owner-scoped capability
marks only a finished local Recording deleted. Repeating deletion succeeds;
absent/inaccessible IDs use `E_RECORDING_NOT_FOUND`, while active/finalizing
Recordings use `E_RECORDING_CONFLICT`. Existing sanitized Recording storage
errors remain authoritative. No method is added to the base SDK interface.

Private schema version 6 adds only
`is_deleted INTEGER NOT NULL DEFAULT 0` to `recordings`. The additive migration
preserves all existing Recordings and routes. History, including pagination,
filters the Recording flag; known-ID detail returns null and route reads fail
with `E_RECORDING_NOT_FOUND`. Normal finish/recovery calls cannot resolve a
deleted Recording. These rules survive restart. The internal Session association
remains reserved, preserving Recording Start semantics.

This is local-only soft deletion, not payload erasure. Route points, gaps,
recovery metadata and History ordering rows may remain in local storage until
normal account/local-user cleanup physically removes Recording storage. No
backend or TAG deletion, HTTP, MQTT, BLE command, Session mutation, SOS or DMP
operation occurs. Active/finalizing restoration is not triggered by deletion.

Hosts guard their own pending End/summary handoff lifecycle before deletion and
refresh authoritative History, close Detail and invalidate route presentation
after success. No delete event stream is provided. Previously delivered values
cannot be retracted; subsequent reads enforce deletion.


### iOS post-migration Bluetooth repair

A verified legacy migration can retain `DeviceMigrationState.bluetoothRepairRequired`
with `DeviceMigrationNextAction.repairBluetooth` and reason
`bluetoothBondRepairRequired`. This requires the migrated target to be connected,
its installation verified, and an iOS notification failure compatible with stale
handles. Generic connection, timeout, permission and backend failures do not
create this state. The pinned BLE plugin preserves operation/platform/error code,
but does not expose the native NSError domain; descriptions are not used because
they may be localized.

`expectedEixamAdvertisingName` exposes the safe display name derived from retained
manufacturing identity. Hosts may guide the user to forget that exact device in
Settings. Resume and the host CTA call `reconcileDeviceMigration()`; one bounded
attempt scans and validates the same identity, checks fresh GATT/version and
notification subscription, then returns `completed` for normal acquisition and
provisioning. Missing, ambiguous or still-stale targets remain actionable. The
repair branch never invokes DFU, including after restart or explicit retry.

`TagPairingCodeCorrelator.verifyMigrated` validates retained migration identity
against a connected post-migration target whose iOS UUID may have changed. The
existing canonical-identity validation remains available for other platforms.
Hosts retire the migration only after successful exact-target acquisition.

### Android location permission upgrade

`AndroidLocationPermissions` provides explicit `getState()`,
`requestForeground()` and `requestBackground()` operations. It reuses the core
`LocationPermissionSnapshot` for grant/accuracy truth and adds Android API level,
request availability, `settingsRequired`, and the OS-localized background option
label. Construction and reads never prompt. Hosts must declare the permissions
needed by their actual feature and explain that feature before a background
request. This helper does not start location collection, tracking, SOS, BLE, or
an Activity route.

Foreground and background requests are separate operations. Before API 29,
foreground access also grants background access. API 29 uses the normal runtime
background permission dialog. API 30+ first attempts the separate official
runtime request where available; the OS controls its destination. When another
native request is unavailable, the explicit action opens the resolvable
`Settings.ACTION_APPLICATION_DETAILS_SETTINGS` fallback. No public Android
intent guarantees a direct app Location-permission screen. A denial never
chains another prompt or Settings launch. A new user action is required.

Request results re-read OS permissions. Returning from app details through Back,
Home/relaunch, or Recents completes with current state. Reads on ordinary app
resume/restart remain the host's responsibility. No grant is persisted; only
prompt-attempt history is stored to decide whether another prompt is possible.
Identical concurrent requests share a result; conflicting operations fail.

Both approximate and precise grants are usable. Foreground-only grants are
never reported as background/permanent readiness. Android has no reliable
public API for an ordinary app to identify the one-time-grant choice;
`temporarilyGranted` is therefore unknown (`null`), and callers must refresh on
resume/restart. The existing iOS background-location adapter is unchanged.
