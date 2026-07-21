# Changelog

All notable changes to the EIXAM Connect Flutter SDK are documented here.

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
