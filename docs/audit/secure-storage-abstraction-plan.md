# Secure Storage Abstraction Plan

Date: 2026-06-22

Scope: SEC-STORAGE Phase 1 plus Phase 2A SDK/app audit remediation prep for `/Users/roger/flutterdev/eixam-sdk-flutter` and `/Users/roger/flutterdev/eixam_commecial_app/eixam-app`.

Phase 1 added a pure Dart abstraction and test implementations only. Phase 2A adds a disabled-by-default app auth-session secure-storage seam and focused tests so the real migration can be enabled deliberately later. Phase 2A does not add a secure-storage dependency, migrate user data, change token format, change default login/session restore behavior, change backend API contracts, touch native Android/iOS project files, or touch SOS/MQTT/BLE behavior.

## Current Mitigation Already Done

- App auth local storage treats `auth.session.*` as sensitive session-restore material.
- App auth restore clears orphaned `auth.session.*` fragments when no access token can restore a session.
- App telemetry persistence stores only `telemetry.last_publish`; legacy `telemetry.publish_history` is no longer written and is removed during writes/clears.
- App telemetry persistence blocks auth-looking strings such as raw `Bearer ...`, `Authorization`, `access_token`, and `refresh_token` values before writing local telemetry metadata.
- SDK `SdkSessionStore` no longer writes the unused optional `refreshToken` into `eixam.sdk.session`; legacy reads remain compatible.
- `docs/audit/local-storage-security-inventory.md` inventories current SharedPreferences keys and sensitivity.

These mitigations reduce exposure but do not fully fix local secret storage because app auth tokens and SDK signed session identity still use SharedPreferences.

## Inspection Result

Neither allowed repo currently has an approved secure-storage dependency. Phase 1 adds the shared pure Dart abstraction to SDK core so the SDK and app can reuse the same contract later without platform wiring in this pass.

| Repo | Current local storage dependency | Secure storage dependency found | Existing relevant abstraction |
| --- | --- | --- | --- |
| SDK `packages/eixam_connect_flutter` | `shared_preferences: ^2.3.2` | No | `SharedPrefsSdkStore`, `SdkSessionStore` |
| SDK `packages/eixam_connect_core` | None in runtime dependencies | No | `SecureKeyValueStore`, `InMemorySecureKeyValueStore`, `UnavailableSecureKeyValueStore`, key namespace helpers |
| App `eixam-app` | `shared_preferences: ^2.5.3` | No | `AuthSessionStore`, `SecureStorageAuthSessionStore`, `SecureStorageBackedAuthSessionStore`, feature stores such as telemetry/DMP/device/profile stores |

Phase 2A dependency decision: do not add `flutter_secure_storage` or another platform-backed secure-storage dependency in this pass. The dependency is low code-size effort, but it can carry platform policy choices for Keychain accessibility, Android backup/keystore behavior, and native test/runtime availability. Keep the production implementation on `UnavailableSecureKeyValueStore` until those decisions are approved.

## Secure Storage Design

Phase 1 introduces a narrow `SecureKeyValueStore` abstraction in `packages/eixam_connect_core/lib/src/storage/secure_key_value_store.dart`, with fake/in-memory and unavailable implementations before any production token migration.

Proposed shape:

```dart
abstract interface class SecureKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<void> deleteAll({String? namespace});
  Future<bool> containsKey(String key);
}
```

Intended responsibilities:

- Store high-risk session secrets and signed identity material behind one SDK/app-local abstraction.
- Keep storage callers independent of the chosen plugin/dependency.
- Provide fake/in-memory implementations for unit tests and migration tests.
- Keep key deletion explicit, auditable, and tied to logout/session invalidation paths.
- Preserve existing serialized value shapes so auth/session restore code can move storage backends without changing token format or backend contracts.
- Expose availability/failure information so secure-storage rollout can fail closed or disable a feature flag intentionally.

Non-goals:

- No token redesign, wrapping, encryption format redesign, rotation policy, or backend API contract change.
- No platform-backed secure-storage implementation in this pass.
- No enabled production auth/session migration in this pass.
- No dependency selection or pubspec change in this pass.
- No native Android/iOS file edits in this pass.
- No migration of existing user data in this pass.
- No changes to SOS, MQTT, BLE, DMP, telemetry publishing, session restore, or login behavior in this pass.
- No claim that local storage is fixed until the implementation and migration phases complete.

## Key Namespace Strategy

Use explicit repo/domain prefixes and versioned key names for future secure-storage keys. Do not reuse SharedPreferences keys inside secure storage unless migration risk analysis explicitly approves it.

Proposed secure key examples:

| Domain | Proposed secure key | Legacy SharedPreferences key |
| --- | --- | --- |
| App auth access token | `eixam.app.auth.session.access_token.v1` | `auth.session.access_token` |
| App auth refresh token | `eixam.app.auth.session.refresh_token.v1` | `auth.session.refresh_token` |
| App authenticated context | `eixam.app.auth.session.authenticated_context.v1` | `auth.session.authenticated_context` |
| SDK signed session identity | `eixam.sdk.auth.session.identity.v1` | `eixam.sdk.session` |

Namespace rules:

- Prefix app-owned keys with `eixam.app.` and SDK-owned keys with `eixam.sdk.`.
- Include domain and purpose: `auth.session`, `tracking`, `sos`, `device`, etc.
- Include a version suffix such as `.v1` for future key rotation or format moves.
- Keep legacy SharedPreferences keys stable until the cleanup phase deletes them.
- Do not store whole authorization headers. Store only the existing token value where current behavior already requires it.

## Candidate Key Classification

| Classification | Keys / values | Rationale |
| --- | --- | --- |
| Must move to secure storage | App `auth.session.access_token`, app `auth.session.refresh_token`, app `auth.session.authenticated_context`, SDK `eixam.sdk.session` signed identity | Required for session restore and high risk if extracted from plaintext SharedPreferences. SDK session writes already remove the unused SDK refresh token; keep that mitigation. |
| Should move later | App `telemetry.last_publish`, app `dmp.monitoring.record`, app `eixam.ble.preferred_device`, app `eixam.device.volumes`, app `profile.onboarding.photo_path`, SDK SOS state keys, SDK pre-SOS/widget keys, SDK tracking/location keys, SDK DMP/contact/device/relay mapping keys | Sensitive safety, location, contact, incident, or device identifiers, but moving them can affect active safety flows and restart continuity. Defer until auth/session migration proves the abstraction and cleanup model. |
| Can stay in SharedPreferences | App onboarding completion flags, profile settings toggles, first-run onboarding flag, SDK permission disclosure acknowledgement, SDK BLE manual-disconnect flag | Non-secret UI/operational state where plaintext local persistence is acceptable after review. |
| Must never be stored | Passwords/login drafts, raw `Authorization` header values, raw `Bearer ...` strings outside the auth token store, telemetry metadata containing auth-looking values, unused SDK `refreshToken` inside `eixam.sdk.session`, backend credentials not already part of the current token/session contract | These are unnecessary for current restore behavior or create avoidable secret proliferation. Existing telemetry blocking and SDK refresh-token omission must not be weakened. |

## Migration Strategy From SharedPreferences

The future migration should be staged and feature-flagged to avoid changing login/session restore behavior unexpectedly.

1. Build and test the abstraction with fake/in-memory stores only.
2. Add a disabled-by-default app config seam before choosing a platform dependency.
3. Add a production secure-store implementation behind the disabled-by-default feature flag.
4. For app auth only, when the flag is enabled:
   - Read secure storage first.
   - If secure storage has no value, read the existing SharedPreferences keys.
   - If migration-on-read is explicitly enabled and SharedPreferences restore succeeds, write the same token/context values to secure storage without changing serialization or token format.
   - Keep legacy SharedPreferences values until the explicit cleanup phase.
5. After app auth telemetry shows stable restore/logout behavior, repeat the same pattern for SDK `eixam.sdk.session`.
6. Only after multiple stable releases, delete legacy SharedPreferences auth/session keys during logout, session invalidation, and a dedicated cleanup pass.

Important migration constraints:

- Do not migrate existing user data in Phase 2A.
- Do not change the meaning, shape, or encoding of token/context values during the storage backend move.
- Do not require backend API changes.
- Do not silently drop users into a broken partial session if one backend read succeeds and the other fails; prefer existing restore semantics and explicit cleanup.
- Do not move SOS/MQTT/BLE/DMP/location keys during the first auth/session migration phases.

## Logout And Session Invalidation Cleanup

Future secure storage implementation must delete secure and legacy keys from every path that currently clears local session material.

App cleanup integration points:

- `SharedPreferencesAuthSessionStore.clear()` currently removes all `auth.session.*` keys.
- `PartnerAuthRepository.clearSession()` calls backend logout when possible and then clears the auth session store.
- `PartnerAuthRepository.clearLocalSession()` clears local auth session state without backend logout.
- `PartnerAppRepository._wipeLocalSessionState(clearAuthSession: true)` clears auth plus DMP, device, telemetry, profile, and in-memory session state.
- Session-invalidating auth failures call local session cleanup through the app repository.

SDK cleanup integration points:

- `SdkSessionStore.clear()` removes `eixam.sdk.session`.
- `EixamConnectSdkImpl.clearSession()` clears SDK session state and calls `sessionStore?.clear()`.

Future secure cleanup rule:

- Auth/session logout or invalidation must delete both new secure keys and legacy SharedPreferences keys while legacy cleanup is still supported.
- Partial cleanup failures must be surfaced to diagnostics without logging key values or token contents.
- Cleanup must remain idempotent; deleting an absent key is success.

## Fallback Behavior If Secure Storage Is Unavailable

Current Phase 2A seam:

- `EIXAM_SECURE_STORAGE_AUTH_SESSION_ENABLED=false` by default, so the app auth session stays on the existing SharedPreferences path.
- `EIXAM_SECURE_STORAGE_AUTH_SESSION_LEGACY_FALLBACK=true` by default, so an explicitly enabled but unavailable secure store can keep the current SharedPreferences path during early rollout.
- `EIXAM_SECURE_STORAGE_AUTH_SESSION_MIGRATE_LEGACY_ON_READ=false` by default, so existing sessions are not automatically migrated on first launch.
- Logout/session invalidation calls through a wrapper that clears both the legacy store and the secure store when one is present; unavailable secure storage is ignored while legacy cleanup still runs.

Recommended rollout behavior after a platform secure store is approved:

- Before secure storage is mandatory, guard secure storage with a remote/build-time feature flag. If the secure store is unavailable at startup, disable the secure-storage path and keep the current SharedPreferences behavior for that release.
- When the flag is enabled for migration, secure-store read failures should fall back to legacy SharedPreferences only if the migration mode explicitly allows fallback and no secure value has already been established.
- Once a value has been written to secure storage, write failures should not silently persist a new secret only to SharedPreferences in secure mode. Fail the operation or disable the flag before rollout rather than creating split-brain session state.
- After secure storage becomes mandatory, unavailability should fail closed: clear incomplete local auth/session state or require sign-in rather than downgrading secrets to SharedPreferences.
- Diagnostics may report availability/error classes, but must not include keys, token values, serialized context, user identifiers, location, or headers.

## Platform Considerations

iOS Keychain:

- Use a dependency/implementation that stores app auth and SDK session values in Keychain.
- Decide Keychain accessibility deliberately before implementation. Candidate policy should favor availability after first unlock for background/session restore only if needed; otherwise prefer a stricter accessibility class.
- Decide whether values should be device-only and excluded from iCloud Keychain migration.
- Confirm uninstall/reinstall behavior expectations because Keychain data may outlive app data depending on configuration.
- Do not modify native iOS project files in this pass.

Android Keystore:

- Use a dependency/implementation backed by Android Keystore or encrypted SharedPreferences.
- Confirm backup/restore behavior and whether encrypted preferences need backup exclusion. Any native manifest/resource changes must be a separate approved native pass.
- Handle keystore invalidation cases, including device lock changes, OS upgrades, restore to another device, and corrupted encrypted preferences.
- Do not modify native Android project files in this pass.

Cross-platform/test:

- Provide fake/in-memory implementations for unit tests so app and SDK logic can be tested without native secure storage.
- Keep web/desktop support explicit if those platforms remain in test or development scope; unsupported platforms should use fake/dev-only stores only outside production.

## Test Plan

Phase 2A adds focused seam tests:

- App config defaults keep secure auth-session storage disabled, legacy fallback enabled, and migration-on-read disabled.
- Disabled seam keeps the auth session on the legacy SharedPreferences-compatible store.
- Enabled seam reads secure storage first when an in-memory secure store is available.
- Optional secure storage falls back to the legacy path when unavailable.
- Logout/session cleanup clears both secure and legacy locations.
- Legacy reads are not migrated unless migration-on-read is explicitly enabled.

Future implementation should add focused tests before production rollout:

- `SecureKeyValueStore` fake/in-memory read/write/delete/deleteAll behavior.
- App auth store secure-first read, legacy fallback read, and migration write-through.
- App auth store cleanup deletes secure and legacy keys.
- SDK session store secure-first read, legacy fallback read, and migration write-through.
- SDK session store continues omitting the unused SDK `refreshToken` on new writes.
- Invalid/corrupt secure values follow current invalid-context cleanup semantics.
- Secure storage unavailable paths honor the feature flag and do not silently downgrade after secure mode is established.
- Telemetry auth-looking value blocking remains covered and unchanged.
- Existing session restore, logout, session invalidation, and local wipe tests remain at least as strict as the current SharedPreferences cleanup/blocking tests.

## Rollout Plan

Phase 0: current mitigation complete.

- Keep app auth orphan cleanup, telemetry latest-only persistence, telemetry auth-string blocking, SDK refresh-token omission, and inventory docs.
- No secure storage dependency or runtime behavior change.

Phase 1: abstraction + fake/in-memory tests.

- Status: complete for the shared SDK core abstraction.
- Added `SecureKeyValueStore`, `InMemorySecureKeyValueStore`, `UnavailableSecureKeyValueStore`, and stable key namespace helpers.
- Added focused SDK core tests for read/write/delete, namespace cleanup, unavailable failures, and key stability.
- No app/SDK auth-session wiring was added in this phase.
- Keep production code on SharedPreferences.

Phase 2A: app auth secure-storage seam prep.

- Status: complete as small code + docs/tests.
- No secure-storage dependency or platform-backed implementation is added.
- Added app config flags:
  - `EIXAM_SECURE_STORAGE_AUTH_SESSION_ENABLED`, default false.
  - `EIXAM_SECURE_STORAGE_AUTH_SESSION_LEGACY_FALLBACK`, default true.
  - `EIXAM_SECURE_STORAGE_AUTH_SESSION_MIGRATE_LEGACY_ON_READ`, default false.
- Added app auth secure-store adapter and wrapper using the SDK core `SecureKeyValueStore` contract.
- Production default remains legacy SharedPreferences because the injected secure store is unavailable and the feature flag is off.
- Safest first real migration target remains the app auth access token, but Phase 2A keeps refresh/context and SDK session behavior unchanged until dependency/platform tests are approved.

Phase 2B: app auth token secure storage behind feature flag.

- Add approved secure-storage dependency.
- Implement a platform-backed app auth secure store behind the off-by-default flag.
- Read secure first, fall back to legacy SharedPreferences during migration, and write the same token/context values to secure storage.
- Do not change login/session restore behavior, token format, or backend contract.

Phase 3: SDK session secure storage.

- Move SDK `eixam.sdk.session` signed identity to secure storage using the same secure-first, legacy-fallback migration pattern.
- Keep SDK `refreshToken` omitted from new session writes.
- Do not move SOS/MQTT/BLE/DMP/location state in this phase.

Phase 4: migration cleanup and old key deletion.

- After stable rollout, remove legacy SharedPreferences auth/session keys on logout, session invalidation, and a versioned cleanup pass.
- Keep cleanup idempotent and observable through redacted diagnostics.
- Revisit sensitive safety/location/contact/device keys as a separate risk-managed migration.

## Risks

- Secure storage plugin choice can require native configuration or backup/accessibility decisions that are outside this pass.
- Keychain/Keystore availability can differ by platform, OS version, device lock state, backup/restore path, and test environment.
- Dual-read migration can create split-brain state if write ordering and cleanup are not carefully tested.
- Keychain persistence across app reinstall may surprise users unless explicitly handled.
- Moving active SOS/DMP/tracking/device keys too early could break safety-flow restart continuity.
- A fallback that silently writes new secrets to SharedPreferences after secure storage is enabled would weaken the migration.

## Blocked / Needs Decision

- Select and approve the secure-storage dependency or internal implementation.
- Decide whether app production code should consume the SDK core abstraction directly or through an app-local adapter when Phase 2 starts.
- Decide iOS Keychain accessibility, migration/synchronization policy, and reinstall behavior.
- Decide Android backup exclusion and keystore invalidation handling; native-file edits, if any, need a separate approved pass.
- Decide feature flag owner, rollout telemetry, and rollback policy.
- Decide when secure storage becomes mandatory and when legacy SharedPreferences auth/session keys are deleted.
- Decide whether and when sensitive safety/location/contact/device keys move after auth/session migration proves stable.
