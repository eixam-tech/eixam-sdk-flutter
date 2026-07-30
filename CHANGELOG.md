# Changelog

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
