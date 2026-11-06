# Changelog

## Unreleased — interrupted DFU recovery and DFU pre-flight

- Optional `DfuRecoveryControl` (status, `watchDfuRecovery`, `prepareCableRecovery`, `restartDfuFromScratch`, `confirmDeviceForgotten`, `dismissDfuRecovery`) with `DfuRecoveryState`, `DfuRecoveryReason`, `DfuRecoveryAction`, `E1RecoveryStrategy` and `resolveE1RecoveryStrategy` (bootloader 0.4.3 and unknown -> cable). BLE resume is not possible with bootloader 0.4.3; recovery is by cable (E1 default: `prepareCableRecovery`).
- Cable recovery installs the EIXAM firmware UF2 directly. Once a cable recovery is in progress (`prepareCableRecovery` done or `physicalRecoveryRequired`), a TAG that comes back running EIXAM firmware ends the interruption: a connected TAG whose application version can be read (any version) is reported as `recovered`; an advertising EIXAM TAG that is not connected yet (unpaired or erased flash) clears the record with `physicalRecoveryCompleted`. Never a version-mismatch card and never an update offer; an older version only shows the normal update card. New read-only `FirmwareUpdateCoordinator.readConnectedApplicationVersion`.
- No automatic DFU: Android `setNumberOfRetries(0)`, watchdogs and plugin detach no longer abort an engaged transfer (abort makes Nordic send Reset and strands the TAG in USB/UF2-only mode), `attemptRecovery` and the old forceDfu recovery are gone (`recoverFirmwareUpdate` throws `remoteRecoveryUnsupported`), iOS connection timeout 30 s.
- Pre-flight before every OTA/migration/recovery start (Bluetooth, foreground, screen, phone battery level and charging); unreadable values are `DfuPreflightWarning`s and never block. BREAKING for hosts: starting needs `FirmwareUpdatePolicy.interruptionWarningAcknowledged` / `migrateDeviceToEixam(interruptionWarningAcknowledged: true)`, otherwise `interruptionWarningNotAcknowledged`.
- `EixamBootstrapConfig.dfuRecovery` (`silenceWindow`, `observeInterval`). `DeviceMigrationFirmwareService.recoverMigrationFirmwareUpdate` removed.
- Stock migration supersedes a stale interrupted firmware record when the TAG reappears as verified stock (hardware model 105, same identity) instead of failing `firmwareUpdateResumeRequired`.
- Native probes `phoneBattery` and `screenAwake`. iOS stale-link detection and the Android task-removal behaviour are unverified on hardware.

## Unreleased — iOS stale-bond detection independent of language

- `E_BLE_IOS_PAIRING_INFORMATION_REMOVED` is now raised from the CoreBluetooth error code (`CBError.peerRemovedPairingInformation`, 14) on FlutterBluePlus apple `connect` failures, which only carry CBErrorDomain. Before, it matched the English `localizedDescription`, which iOS localizes, so Catalan and Spanish iPhones got a generic connection error. Other operations, where 14 can be `CBATTError.unlikelyError`, keep the English text match as a fallback. No API change.

## Unreleased — pairing list display classifier

- `EixamBleScanResult.pairingDisplayCategory` (`eixam`, `legacyOrStock`, `dfuRecovery`, `hidden`; `null` = not classified) computed from the fresh advertisement by the pure-Dart `classifyEixamPairingDisplay`. Shows the Eixam or stock service, names `EIXAM_*`, `N6*`, `Meshtastic_*`, `AdaDFU` and the DFU service; hides `EIXAM_GW_*` and everything else.
- `EixamPairingDisplayFilter` keeps a device that was already shown visible when a later result lacks the name (iOS scan response), but still hides an explicit gateway name.
- Display-only and additive: scanning, brand classification, `isDfuBootloader`, identity, migration and connection paths are unchanged. The category never authorizes a connection.

## Unreleased — TAG disconnect alerts

- Dart-side "TAG forgotten or dropped" alert: a dead-man local notification armed while the link is up (pushed at most every clamp(X/4, 60 s, 10 min), firing X to 1.25 X after the last contact), rescheduled to exactly drop + X when an unexpected drop is observed, and removed on reconnect. Bluetooth off raises the `bluetoothOff` kind.
- Suppressed for manual disconnects/unpair, firmware updates, device migration, the provisioning reboot window, SOS and a missing notification permission. The lease (the periodic push) is dropped while backgrounded on iOS and Android; arm-at-disconnect still schedules `drop + X` when Dart observes a drop in the background. Drops seen by the native owner use the native timestamp. A background drop is scheduled using the last known permission state (no permission round-trip, cleanup retry deferred) to fit the iOS wake window. Debug `[TAG_LEASE]` log lines (no identifiers, with `dropToScheduleMs`) help device tests. No new public API; the liveness signal is the passive OS connection state (no extra BLE traffic).
- The notifier caches the slot id, so a lease push costs one platform call instead of three.
- Background (suspended app, killed process) still depends on a future native arm-at-disconnect.
- Physically validated (QA 03/11). iOS (iPhone 15): background disconnect alert after 5 min, 30 min with TAG nearby -> no false alerts, Bluetooth off >5 min alert. Android (Xiaomi, Android 13): disconnect alert arrives between 5:00 and 8:44 (inexact alarm / Doze), accepted for v1; Android 30-min and Bluetooth-off tests not run. App killed or swiped from recents: no alert (documented limitation).

## Unreleased — TAG low-battery alerts

- Low-battery alerts at < 30 % and < 10 % from live TAG data only, with two-reading
  confirmation for firing and rearming, phone-like rearm on each downward crossing,
  and a persisted per-device cycle (`TagBatteryAlertPolicy`, `TagBatteryCycle`).
  Sources: `0xD3` live batches (fresh timestamped sample), own classic TEL and
  `0x23`; backlog, relays, SOS packets and stored status are never readings.
- One `0x23` on a real foreground return (at most every 10 min per device, skipped
  during SOS, firmware update, provisioning and migration). No polling, no new
  BLE command, no native change. Alerts need live TAG data: a stationary TAG or a
  backgrounded app produces none.
- Review fixes: the resume probe now waits for SOS rehydration, re-checks its gate right before the send and sends only when the command path is already ready (it can no longer start a reconnect or rebind); delivery is at-least-once (show first, mark afterwards) and is not consumed while notification permission is blocked; device-scoped readings must match the current device id; the freshness window scales with the TEL interval (`max(3 min, 1.5 x interval)`, cap 30 min).
- Known pre-existing issue, not changed: a newly paired TAG can keep the previous TAG's `nodeId` when the pair-time `0x23` misses (`ble_device_runtime_provider.dart:449,644,1303`).
- Battery alerts continue during an SOS (own channel, no SOS interaction).
- Not physically validated: no discharge test below 30 % / 10 % was run. Covered by unit/integration tests only. Pending physical QA.


## Unreleased — TAG alerts foundation

- Add optional `TagAlertsControl` (per-TAG `TagAlertSettings`, permission state and
  request), the `TagAlertNotifier` port, `TagAlert`/`TagAlertText` contracts and a
  default local-notification adapter (channel `eixam_tag_alerts`, `tag_alert:`
  payloads, reserved id range `1000000000..1000099999`, inexact scheduling).
  Optional `tagAlertNotifier` / `tagAlertTextResolver` on `EixamBootstrapConfig`.
  No battery source and no disconnect policy yet: the SDK emits no TAG alert.
- Settings persist under `eixam.tag_alerts.v1` and are wiped with their alerts on
  `clearSession`, `clearLocalUserData`, identity/app change and unpair.
- A cold-start session restore that throws (locked keychain, transient storage error) no longer wipes TAG alert settings or scheduled alerts; only a completed restore with no session or an explicit logout does.
- The SDK ignores `tag_alert:` notification taps in SOS/BLE navigation (an
  unrecognized payload used to reach a JSON parser there).
- SDK manifest now declares the `flutter_local_notifications` scheduled and boot
  receivers and `RECEIVE_BOOT_COMPLETED`; new dependency `timezone ^0.11.0`.
  Hosts need core-library desugaring. SOS flows, channels and payloads are unchanged;
  the generic notification id generator now avoids the reserved range.
- The TAG alert key is the canonical hardware id, else the transport device id, and never the firmware node id (on iOS the node id arrives after the pair-time `0x23` timeout and would change the key). Device country config keeps its own key. A completed device migration re-keys settings and removes the old key's alerts (`DeviceMigrationCoordinator.onDeviceIdentityMigrated`).
- Cleanup that the notifier could not complete (error or 5 s timeout) is retried before every operation and surfaced to watchers; notifier calls inside the serialized tail are bounded.
- Not a guaranteed safety feature; local notifications can be delayed or dropped.
- Validated indirectly in QA 03/11 (iOS: TAG settings section, notification permission flow and settings persistence PASS).

## Unreleased — post-cancel SOS convergence

- A TAG that the user already cancelled (`0xE1`) is now clear proof for the
  redundant remote-terminal clear that the backend echo dispatches, so the
  device mirror converges at once instead of waiting for an `0xE2` that never
  comes. Before this, a second TAG SOS was suppressed for minutes on Android.
- A dispatched remote-terminal clear without a matching `0xE2`/`0xE3` now moves
  the device mirror to `failed` after 10 s, which ends post-terminal
  suppression. A late matching ack still converges it to `synchronized`.
- Replays are still rejected: a new physical start after a terminal needs a
  receive newer than the observed TAG closure. No change to commands, backend
  calls, notifications or native code.
- Physically validated on iPhone 15 and Xiaomi Android 13 (QA 03/11): no ghost SOS
  2 min after cancel; second TAG SOS accepted (iOS 18/68 s, Android 39/99 s); TAG SOS
  after a prior cancel with app backgrounded and locked; app SOS + cancel. Firmware
  dependency open: the TAG must never resend a cancelled-cycle SOS packet after `E1`.

## Unreleased — iOS false "SOS active" from TEL frames

- Fix iOS native SOS parsing (introduced in 340c548b, present in `main` and `develop`):
  a `0xD3` live batch with one record is exactly 18 B and arrives about every 120 s. The
  parser mapped 18 B to a 12 B SOS and 13 B to a 7 B SOS, so random record bytes produced
  a false `.active` (an "SOS active" notification and an SDK `sent` snapshot), a false
  `.preSos`, or a `.cancelled` that could locally cancel a real SOS.
- Remove the 13/18 B mapping. Known TEL frames (`0xD3`, `0xD1`, `0xD2`, `0xD8`, `0xDA`,
  `0xDB`, the `0x23` reply and CMD results) are matched by opcode and structure and are
  not SOS. A 12 B frame on TEL is SOS only if `bit5(flags) == 0 && sosType == 3` and is
  never a cancellation otherwise (Android parity). The SOS characteristic, `0xE1`/`0xE2`/
  `0xE3` and notification ids, texts and payloads are unchanged.
- INET (`ea03`) and CMD (`ea04`) notifications are never SOS candidates on iOS; SOS
  arrives on the SOS and TEL characteristics only.
- `EixamBleProtocol.isReservedSosOrTelNotifyLength` and the Dart "+6" wrapped-SOS lengths
  are legacy and unused by the iOS parser; they are left untouched.
- Physically validated on iPhone 15 (QA 03/11): 30 min background with a TAG nearby
  produced no false SOS; real TAG SOS, cancel and app SOS unchanged; INET/CMD non-SOS.

## Unreleased — robust activity recording finalization (AR2C-B)

- Persist immutable finish cutoffs and five-second final catch-up deadlines; resume
  finalizing recordings locally after process restart.
- Finish connected, disconnected, partial, busy and timed-out recordings with an
  immutable committed result; coalesce owned recovery and fence late D3/D1 data.
- Reconcile ambiguous storage acknowledgements, preserve retained finished routes
  through schema v4 migration and keep the optional public API unchanged.
- Physical AR2B-HW1 validation remains deferred; app orchestration belongs to AR3.

## Unreleased — logical activity sessions

- Add optional `ActivitySessionControl` and `SdkActivitySession` without adding
  required SDK facade members or expanding the sealed SDK error hierarchy.
- Serialize identity-scoped start/end/restoration with checked persistence,
  private end tombstones, safe observation, and an in-isolate writer lease.
- Keep product activity catalogs, partner context, tracking, SOS, and DMP outside
  the capability. Existing consumers need no source changes to compile.


## Unreleased — cycle-bound LoRa return (2026-10-15)

- Preserve the bound SOS packet reference when enriching a no-fix receipt with last-known position. The stopped D1 exposed this missing copy before WEB ACK; captured-receipt runtime regressions cover SOS/TEL and retained fix age. Physical return validation remains pending.

- Bind ACK/RESOLVE/CANCEL to the actual first completed SOS packet, canonical backend incident and observed relay transport. New versioned E4 receipt and0B command fail closed without cycle proof. Android/iOS native ingress retains remote identity; both hosts must pin this SDK. Details: `docs/LORA_CYCLE_BOUND_RETURN.md`. Local implementation only; D1–D3 physical validation pending.

All notable changes to the EIXAM Connect Flutter SDK are documented here.

## Unreleased - 2026-07-27

No package version is assigned by this entry.

### Added

- SDK-owned SOS phone-location acquisition and context arbitration that
  preserves Profile sharing when an SOS context ends.
- Stable connected-device SOS generations, immediate active handoff, local
  terminal classification, and immediate rearm after a confirmed terminal
  boundary.
- Provisional-to-canonical incident handoff with versioned backend and
  emergency-contact progress.

### Changed

- Removed a stale Contacts collection declaration from the Flutter iOS
  plugin privacy manifest. The SDK does not access the system address book;
  emergency-contact records are supplied explicitly by the host or backend.
  No runtime behavior or public API changed, and packages remain at `0.3.0`
  because the App consumes an immutable private Git release unit.
- Hardened SOS lifecycle handling against duplicate/stale packets, delayed
  countdown observations, cancellation races, and reconnect snapshots.
- Release diagnostics now use redacted presence/category fields; verbose
  device and location traces remain debug-only and opt-in.
- iOS Core Location service status is cached from delegate/application
  updates; the global service query runs off the main queue and is not called
  synchronously during sample delivery.

### Validation scope

- Automated checkpoint at commit `edbfd2328f759ee94908d8d72c201a26cd69670e`:
  665 SDK tests passed.
- App-origin and connected-local-device flows, progress handoff,
  cancellation/rearm, map updates, sharing coexistence, and privacy-safe
  diagnostics were physically and backend validated against staging.
- This is not evidence of a production backend deployment or a production
  store release.

## 0.3.0 - 2026-07-21

### Added

- SDK-owned OTA firmware updates with eligibility checks, progress reporting,
  cancellation, recovery, and post-update verification.
- Country-aware LoRa region resolution and an explicit, user-confirmed device
  configuration flow.
- Authoritative SOS lifecycle, capability, incident-progress, and history models.
- Preferred-device reconnect campaigns with typed public outcomes.
- Centralized location authority, Android SOS widget support, permission
  disclosures, and account data deletion APIs.

### Changed

- Expanded operational diagnostics and hardened BLE, relay, MQTT, protection,
  background-runtime, and secure-storage behavior.
- Exported `PreferredDeviceReconnectResult`, `SosHistoryItem`, `SosHistoryPage`,
  and `SosIncidentProgress` from the partner-facing package entrypoint.
- Updated package metadata to point to the public documentation and repository.

### Integration notes

- `EixamBootstrapConfig.notificationTexts` is required. Provide non-empty,
  app-localized text for every notification field.
- LoRa region changes require an explicit host-app confirmation before the SDK
  writes the resolved country configuration to the device.
- OTA and LoRa region operations require a ready BLE command channel; consume
  the typed SDK state and progress streams instead of parsing protocol bytes.
