# SDK/App Local Storage Security Inventory

Date: 2026-06-22

Historical checkpoint: retained for audit evidence. Since this date, the SDK
added a platform-backed secure store for the minimal account-scoped SOS
provenance record. That does not by itself resolve the broader auth-token,
telemetry, tracking, backend, or migration risks catalogued below. For current
SOS persistence, see `../SOS_LIFECYCLE_ARCHITECTURE_2026.md`.

Scope: SDK/app-only audit remediation for this SDK and the partner-app
repository. Backend, firmware, native Android/iOS project files, generated
files, and build/test cache are intentionally out of scope.

Checkpoint status at 2026-06-22: local storage was partially mitigated, not
fully fixed. Secure storage migration was designed/planned in
`secure-storage-abstraction-plan.md`; Phase 1 provided a pure Dart SDK core
abstraction, Phase 2A added a disabled-by-default app auth-session seam, and
Phase 2B completed app-only fallback/kill-switch guardrails around that seam.
At that checkpoint no platform-backed implementation or real token/session
migration existed.

Classification:

- A: required for session restore
- B: required for offline queue or restart continuity of active safety flows
- C: non-sensitive operational cache
- D: sensitive but currently necessary
- E: sensitive and unnecessary / should not persist

## App SharedPreferences

| Key | Owner | Contents | Class | Current mitigation / action |
| --- | --- | --- | --- | --- |
| `auth.session.access_token` | `SharedPreferencesAuthSessionStore` | App access token | A, D | Required by current app session restore. Cleared on logout, session invalidation, and now when no access token can restore the session. Secure storage is a next action because no secure-storage dependency exists in this pass. |
| `auth.session.refresh_token` | `SharedPreferencesAuthSessionStore` | App refresh token | A, D | Required for refresh/restore. Cleared with access token and orphan fragments. Secure storage is a next action. |
| `auth.session.authenticated_context` | `SharedPreferencesAuthSessionStore` | User id/email/profile fields, SDK userHash, SDK ids, optional SDK refresh token | A, D | Required to restore app/SDK context without changing backend contracts. Invalid context is removed. Orphan context is now cleared when no access token exists. |
| `telemetry.last_publish` | `SharedPreferencesTelemetryPublishStore` | Last published lat/lon, source, device/incident ids | B, D | Needed for telemetry throttling across app restarts. Reduced from latest plus 64-entry history to latest-only. Auth-looking strings are blocked before persistence. Cleared on logout/local wipe. |
| `telemetry.publish_history` | `SharedPreferencesTelemetryPublishStore` | Legacy telemetry lat/lon history | E | No longer written. Removed during next telemetry write or explicit clear. |
| `dmp.monitoring.record` | `SharedPreferencesDmpMonitoringStore` | DMP expected return timestamps | B, D | Required to preserve active DMP monitoring. Cleared on logout/local wipe/reset/check-in. |
| `eixam.ble.preferred_device` | `SharedPreferencesPreferredDeviceStore` | Preferred BLE device id/display name/last connect time | C, D | Useful operational cache. Cleared on local wipe/logout path. Device ids remain sensitive operational identifiers. |
| `device.preferred.record` | `SharedPreferencesPreferredDeviceStore` | Legacy preferred BLE device record | C, D | Migrated to SDK-native key and removed. |
| `eixam.device.volumes` | `SharedPreferencesDeviceVolumeStore` | Per-device volume settings keyed by device identifiers | C, D | Operational preference. Cleared on local wipe/logout path. |
| `profile.onboarding.completed` | `SharedPreferencesOnboardingProfileStore` | Onboarding completion flag | C | Non-sensitive app state. Cleared on local wipe. |
| `profile.onboarding.photo_path` | `SharedPreferencesOnboardingProfileStore` | Local profile photo path | D | Local profile metadata. Cleared on local wipe. |
| `profile.onboarding.first_name`, `profile.onboarding.last_name`, `profile.onboarding.phone_number`, `profile.onboarding.home_address`, `profile.onboarding.email` | `SharedPreferencesOnboardingProfileStore` | Legacy synced profile PII | E | Existing migration clears these fields and stores safe defaults. |
| `profile.settings.auto_broadcast_location`, `profile.settings.biometric_authentication_enabled`, `profile.settings.critical_sound_alerts_enabled` | `SharedPreferencesProfileSettingsStore` | Local profile settings | C | Non-secret operational settings. Cleared on profile local-state wipe. |
| `first_run_onboarding.completed` | `SharedPreferencesFirstRunOnboardingStore` | First-run onboarding flag | C | Non-sensitive app state. |
| App notification coordinator keys | `LocalAppNotificationService`, SOS/DMP notification coordinators | Notification action/session dedupe ids | B, D | Required to avoid duplicate user-facing safety notifications. Not auth material. |

## SDK SharedPreferences

| Key | Owner | Contents | Class | Current mitigation / action |
| --- | --- | --- | --- | --- |
| `eixam.sdk.session` | `SdkSessionStore` | Signed SDK identity: app id, external user id, userHash, SDK ids | A, D | Required for SDK session restore. New writes no longer persist the unused optional SDK refresh token; legacy reads remain compatible. Secure storage is a next action because no secure-storage dependency exists. |
| `eixam.sos.active_incident`, `eixam.sos.state`, `eixam.sos.closed_incident` | SOS repositories | Active/closed SOS incident state, location snapshot, backend/device ids | B, D | Required for SOS restart continuity and lifecycle correctness. Cleared by SOS state transitions and SDK `clearSession` where applicable. |
| `eixam.sos.pre_sos_session` | `EixamConnectSdkImpl` | Pre-SOS cycle timing, owner/origin, optional trigger payload | B, D | Required for app/device pre-SOS restart behavior. Cleared on session clear and pre-SOS completion/cancel. |
| `eixam.sos.os_widget.recent_actions` | `EixamConnectSdkImpl` | OS widget idempotency keys/timestamps | B, D | Required to dedupe SOS widget actions. Time-bounded. |
| `eixam.tracking.last_position`, `eixam.tracking.state` | `GeolocatorTrackingRepository` | Last tracking location and state | B, D | Required for tracking restart continuity. Location remains sensitive and should be moved to secure/encrypted storage in a later pass. |
| `eixam.location.resolved` | `EixamConnectSdkImpl` | Native handoff of resolved authoritative location | B, D | Required for native/background handoff. Contains location telemetry. |
| `eixam.death_man.active_plan` | `InMemoryDeathManRepository` | Active DMP plan | B, D | Required for DMP restart continuity. Removed on cancel/resolve. |
| `eixam.contacts.list` | `InMemoryContactsRepository` | Emergency contacts if using local/in-memory repository with persistence | B, D | Sensitive emergency contact data. Current production app path uses SDK remote contacts, but this key remains sensitive in SDK local-store inventory. |
| `eixam.device.status` | Device repositories | Connected device status and identifiers | C, D | Operational cache. Device identifiers treated as sensitive. |
| `eixam.ble.preferred_device` | `PreferredBleDeviceStore` | Preferred BLE device id/display name | C, D | Operational cache. |
| `eixam.ble.manual_disconnect_requested` | `PreferredBleDeviceStore` | Manual disconnect flag | C | Non-sensitive operational flag. |
| `eixam.device.identity_mappings` | `EixamConnectSdkImpl` | Relay node to hardware-id mappings | B, D | Required for relay/SOS identity continuity. TTL-pruned. |
| `eixam.sos.external_relay_contexts` | `EixamConnectSdkImpl` | Recent relay SOS context, backend incident ids, device ids | B, D | Required for relay handoff/dedup continuity. TTL-pruned. |
| Permission disclosure ack key | `EixamConnectSdkImpl` | Permission-disclosure acknowledgements | C | Non-secret UI state. |

## Out of Scope / Next Actions

- Secure storage migration is designed/planned in `docs/audit/secure-storage-abstraction-plan.md` but not fixed in this checkpoint: neither app nor SDK currently declares a secure-storage dependency or platform-backed implementation, and secure auth-session storage remains disabled by default. Complete manual Android/iOS login/session QA, then decide whether to add a real platform secure-storage dependency behind the disabled flag before considering app token/session migration.
- Backend token redesign, token rotation, token shape changes, and MQTT/server authorization changes are out of scope.
- Firmware/native storage behavior is out of scope.
- Remaining sensitive-but-required location, SOS, DMP, relay, emergency contact, and device-id persistence should be encrypted or minimized further once a secure local storage abstraction is available.
