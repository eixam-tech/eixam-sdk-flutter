# SDK/App Audit Remediation Tracker

Status: SDK/app-only checkpoint for Dani audit remediation after SEC-BLE Phase 0 SDK-only scaffolding, ARCH-APP-5.3 `LiveEixamSdkClient` typed seam audit, ARCH-SDK-2 second-pass public SOS stream boundary cleanup, stale override cleanup, aggregate QA gate pass, and expanded Android manual QA checkpoint.

Global checkpoint: `docs/audit/sdk-app-audit-global-checkpoint.md`.

Future PR/patch guardrails checklist: `docs/audit/sdk-app-audit-guardrails-checklist.md`.

Firmware/backend/broker/protocol handoff for Dani: `docs/audit/dani-firmware-backend-audit-handoff.md`.

This tracker is intentionally scoped to:

- SDK: `/Users/roger/flutterdev/eixam-sdk-flutter`
- App: `/Users/roger/flutterdev/eixam_commecial_app/eixam-app`

Do not use this tracker as approval to change backend, firmware, protocol server code, generated files, native Android/iOS project files, production/runtime code, or `build/test_cache`. Firmware/backend-required findings below are not fixed unless explicitly marked fixed by a later firmware/backend remediation pass.

Allowed finding classifications:

- Fixed SDK/App
- Strongly mitigated SDK/App
- Partially mitigated SDK/App
- Design-only
- Blocked by firmware/backend
- Blocked by backend/platform
- Future hardening

## Current Checkpoint Summary

- SDK typed SOS authority metadata is complete.
- App conservative SOS authority fallback is complete.
- TEST-2 `SosStateMachine` coverage is complete for the current lifecycle rules.
- App synthetic SOS sending has been removed.
- SOS-DEV-1 remote relay handoff dedup fail-safe is complete in the SDK boundary.
- ARCH-APP-3 / SOS-REPO-12 lifecycle authority guardrails are in place.
- SOS-REPO-12.1 identity-bounded app compatibility guards are in place.
- SEC-NET-3 MQTT lifecycle authority gate is in place.
- SOS-SDK-1 device-only SOS success is in place.
- Sensitive diagnostics / PII redaction is in place.
- SEC-BLE Phase 0 SDK-only scaffolding is complete as a partial mitigation: policy/capability/decision scaffolding, command criticality, legacy-compatible diagnostics, stable BLE error-code reservations, and focused tests are in place.
- SEC-BLE full remediation remains blocked by firmware/protocol support for authenticated BLE links, command integrity, cryptographic pairing, replay rejection, and authenticated identity.
- SDK/app-only audit tracker is current for this checkpoint.
- ARCH-APP-5.3 `LiveEixamSdkClient` typed seam audit is complete and strongly mitigated app-side: remaining dynamic/Object?/Map/`NoSuchMethodError` usage is inventoried at the injected SDK runtime boundary, one critical pre-typed/test fake SOS authority fallback is centralized in `_legacyDynamicSdkFallbackSosAuthorityFromIncident(...)`, and significant typed runtime seam work remains future scope.
- Stale override cleanup is complete in `live_eixam_sdk_client.dart`: four stale `@override` annotations were removed without changing method bodies, names, signatures, or runtime behavior.
- Aggregate QA passed before this docs-only checkpoint across the app, SDK core, and SDK Flutter gate list below; no tests were run as part of this docs-only update.
- ARCH-SDK-2 second-pass public SOS stream boundary cleanup is complete and strongly mitigated: public SOS state writes are centralized through `_emitPublicSosState` / `_applyPublicSosState`, canonical transitions still route through `SosStateMachine.canTransition(...)`, and retained bypasses are explicit source allow-lists with diagnostic context rather than broad source-string predicates.
- Some public SOS state-machine bypasses remain intentional for authoritative/compatibility paths: repository/backend terminal authority, repository rehydration, device runtime overrides, app-trigger publish shortcut, explicit idle clears, and external/remote-relay isolation clears. These are not eliminated; they are constrained and diagnostic-rich with `reason`, `authority`, `origin`, and `policy`.
- External/remote relay paths continue to clear or remain idle as `external_remote_relay_isolation`; they do not become local active SOS through the public stream boundary.
- Remote relay SOS test-debt cleanup is complete: stale decoder expectations, HTTP-era assertions, active-device PRE-SOS countdown behavior, and correlated backend cancel setup are aligned with current SDK behavior.
- SEC-NET endpoint hardening is complete for the SDK/app boundary.
- SEC-NET hardening inventory is documented in `docs/audit/network-security-hardening-inventory.md`. It confirms SDK/app endpoint and transport guardrails, MQTT-only SOS trigger policy, HTTP cancel/read-only preservation, MQTT lifecycle authority gating, auth/token handling, diagnostics redaction, and local/secure-storage interaction without changing runtime behavior.
- Local storage hardening is partially mitigated: app auth orphan fragments are cleaned up, telemetry is latest-only, telemetry auth-token/header persistence is blocked, the SDK no longer writes the unused refresh token, and the local-storage security inventory is documented.
- Secure storage migration is now designed/planned in `docs/audit/secure-storage-abstraction-plan.md`; Phase 1 adds a pure Dart SDK core abstraction, Phase 2A adds a disabled-by-default app auth-session config seam with tests, and Phase 2B completes app-only fallback/kill-switch guardrails around that seam. It is not fixed because no secure-storage dependency, platform-backed implementation, enabled flag, real token/session migration, or user-data migration exists yet.
- Expanded Android manual QA checkpoint passed on 2026-06-27 for Auth/session, SOS without device, Devices/BLE, SOS with connected device, and Background/resume. Remote relay/LoRa manual QA was not tested in this round and must not be treated as passed. iOS QA remains deferred to final acceptance.

## Completed SDK/App Mitigations

| Finding id | Classification | Repo scope | Risk level | What has been done | What remains | Next recommended action |
| --- | --- | --- | --- | --- | --- | --- |
| SOS-AUTH-META | Fixed SDK/App | SDK | High | SDK incidents now carry typed SOS authority metadata so app consumers can distinguish SDK-owned/local-actionable SOS from external/backend-only records. | Continue preserving typed authority as the source of truth. | Add regression coverage whenever incident mapping changes. |
| APP-SOS-AUTH-FALLBACK | Fixed SDK/App | app | High | App applies conservative fallback when typed SDK SOS authority is missing, treating the incident as external/history-only instead of active local authority. | Backend history without SDK authority still cannot become local-actionable from app logic alone. | Keep app fallback conservative; do not reintroduce app-side lifecycle authority. |
| TEST-2 | Fixed SDK/App | SDK | Medium | `SosStateMachine` lifecycle coverage exists for SDK state transitions and edge cases. | Coverage must be extended with any new lifecycle behavior. | Keep targeted state-machine tests close to future SOS lifecycle changes. |
| APP-SOS-SYNTHETIC | Fixed SDK/App | app | High | App synthetic SOS sending was removed, so UI no longer fabricates sending/active state outside SDK authority. | App still depends on SDK state fidelity. | Preserve thin-app rule: render SDK state, do not recreate SOS state machines in widgets/repositories. |
| SOS-DEV-1 | Strongly mitigated SDK/App | SDK | High | Remote relay handoff now has dedup/fail-safe behavior so duplicate relay backend handoffs are constrained. | Cryptographic relay origin proof is not provided by this SDK-only fix. | Keep relay retry/dedup SDK-owned; defer authenticated relay origin to SEC-BLE/protocol work. |
| ARCH-APP-3 / SOS-REPO-12 | Fixed SDK/App | SDK+app | High | Guardrails keep SOS orchestration, relay routing, and raw BLE handling in SDK/runtime layers rather than app widgets. | Future app changes can regress this boundary. | Enforce via review: app may call typed SDK APIs only. |
| SOS-REPO-12.1 | Strongly mitigated SDK/App | app | High | App guards are identity-bounded, preventing backend/history snapshots without SDK authority from recreating local active SOS. | BLE node identity is still not cryptographically authenticated. | Keep repository guards tied to SDK authority and known identity evidence. |
| SEC-NET-3 | Strongly mitigated SDK/App | SDK | High | MQTT lifecycle authority gate prevents unrelated realtime/backend lifecycle events from taking local SOS authority. | Backend/server authorization is outside this SDK/app boundary. | Preserve topic/session authority checks during realtime refactors. |
| SEC-NET-ENDPOINT | Strongly mitigated SDK/App | SDK+app | High | Endpoint handling was hardened within the SDK/app boundary so callers use HTTPS/WSS or secure MQTT schemes outside explicit debug-local overrides and avoid unsafe endpoint drift. | Server-side endpoint authorization, infrastructure controls, certificate pinning, custom TLS trust, and broker/topic ACLs remain backend/platform-owned or future hardening. | Preserve centralized endpoint construction and review any future dynamic endpoint inputs; use `docs/audit/network-security-hardening-inventory.md` before selecting the next SEC-NET implementation. |
| SOS-SDK-1 | Fixed SDK/App | SDK | High | SDK supports device-only SOS success when backend is unavailable but a valid device SOS path succeeds. | Device command path security remains subject to SEC-BLE limitations. | Keep one-successful-channel semantics covered by SDK tests. |
| SEC-DIAG-PII | Fixed SDK/App | SDK+app | Medium | Sensitive diagnostics and PII redaction were added for SDK/app logs, raw payloads, identity values, topics, headers, and payload bodies. | New diagnostic fields can reintroduce sensitive data if not routed through redactors. | Require redaction review for all new diagnostics. |
| ARCH-APP-5 | Strongly mitigated SDK/App | app | Medium | Typed SDK boundary second pass is complete in `partner_sdk_adapter.dart`: the SOS adapter path now uses `SdkSosSnapshot`, and remaining remote-relay SDK event dynamic access is centralized behind `_legacySdkEventStream()`. ARCH-APP-5.3 is also complete in `live_eixam_sdk_client.dart`: remaining dynamic/Object?/Map/`NoSuchMethodError` usage is inventoried at the injected SDK runtime boundary, and the critical pre-typed/test fake SOS authority fallback is centralized in `_legacyDynamicSdkFallbackSosAuthorityFromIncident(...)`. | `LiveEixamSdkClient` still has significant dynamic runtime seam work that belongs to a larger future pass. It is not fully typed. | Keep app code on typed SDK APIs and plan remaining `LiveEixamSdkClient` seam work separately; do not claim dynamic access is fully eliminated. |
| APP-STALE-OVERRIDE-CLEANUP | Fixed SDK/App | app | Low | Removed four stale `@override` annotations from `live_eixam_sdk_client.dart` after the typed seam audit. No method bodies, names, signatures, or runtime behavior changed. | None for the stale override warnings identified in this checkpoint. | Keep analyzer clean when adapter interfaces or implementation signatures change. |
| ARCH-SDK-2 | Strongly mitigated SDK/App | SDK | Medium | Public SOS stream guard second pass is complete. Public state writes now flow through `_emitPublicSosState` / `_applyPublicSosState`, direct `_publicSosState` and `_publicSosStateController.add(...)` mutation is centralized, canonical transitions still use `SosStateMachine.canTransition(...)`, broad bypass predicates were replaced with explicit source allow-lists, retained bypass diagnostics include `reason`, `authority`, `origin`, and `policy`, and focused lifecycle coverage asserts the retained repository terminal bypass diagnostic. External/remote relay paths still clear or remain idle as `external_remote_relay_isolation` instead of becoming local active. | Intentional bypasses remain for repository/backend terminal authority, repository rehydration, device runtime overrides, app-trigger publish shortcut, explicit idle clears, and external/remote-relay isolation clears. These are constrained and diagnostic-rich, not eliminated. | Preserve the centralized public SOS boundary and explicit allow-lists during future lifecycle work; extend focused regression coverage when a retained bypass class changes. |
| REMOTE-RELAY-SOS-TEST-DEBT | Fixed SDK/App | SDK tests | Medium | `remote_relay_sos_backend_handoff_test.dart` now matches current decoder output, MQTT contract/repository paths, active-device PRE-SOS countdown promotion, and backend cancel correlation requirements. The remote relay SOS handoff test debt is cleaned up without runtime behavior changes. | Continue keeping relay tests aligned to SDK contract changes. | Keep this test in the QA gate list for future relay/SOS work. |

## Partial SDK/App Mitigations

These findings are reduced from SDK/app, but they are not fully fixed in the current boundary.

| Finding id | Classification | Repo scope | Risk level | What has been done | What remains | Next recommended action |
| --- | --- | --- | --- | --- | --- | --- |
| SEC-NET-LOCAL-STORAGE | Partially mitigated SDK/App | SDK+app | High | Added `docs/audit/local-storage-security-inventory.md`; reduced app telemetry persistence from a 64-entry location history to latest-only; blocked auth-looking strings from app telemetry persistence; cleared orphan app auth fragments when restore cannot authenticate; stopped new SDK session writes from persisting the unused SDK refresh token while keeping legacy reads compatible; added Phase 1 SDK core secure key-value abstraction and fake/unavailable implementations; added Phase 2A app auth-session config seam with secure-store/fallback tests; added Phase 2B app-only fallback/kill-switch guardrails around disabled secure auth-session storage. | App auth tokens, SDK signed identity, location/SOS/DMP/device/contact state still use SharedPreferences by default because no secure-storage dependency, platform-backed implementation, enabled flag, real token/session migration, or user-data migration exists in this pass. | Manually QA login/session restore on Android and iOS, then decide whether to add a real platform secure-storage dependency behind the disabled flag; keep backend auth format unchanged. |
| SEC-STORAGE-SECURE-MIGRATION | Partially mitigated SDK/App | SDK+app | High | Secure-storage migration is designed/planned in `docs/audit/secure-storage-abstraction-plan.md`: it defines `SecureKeyValueStore`, candidate key classification, SharedPreferences migration strategy, logout/session cleanup, fallback behavior, platform considerations, tests, risks, blocked decisions, and phases 0-5. Phase 1 adds the pure Dart SDK core abstraction, in-memory test store, unavailable store, stable key namespace helpers, and focused unit tests. Phase 2A adds disabled-by-default app flags for auth-session secure storage, legacy fallback, and migration-on-read; an app auth secure-store adapter; a wrapper that clears both secure and legacy locations; and focused seam tests. Phase 2B completes app-only guardrails for disabled secure path, unavailable secure storage, fallback false, best-effort clear, migrate-on-read ordering, corrupt secure payload fallback behavior, and default/preview config. | It is not fixed: no secure-storage dependency has been added, no platform-backed implementation exists, no secure-storage flag is enabled, no data has migrated, and app auth tokens plus SDK signed identity still use SharedPreferences by default today. | Next: manual QA login/session behavior on Android and iOS; decide whether to add a real platform secure-storage dependency behind the disabled flag; only then consider Phase 3 app token/session migration. |
| SEC-BLE-1 | Partially mitigated SDK/App | SDK | Critical | Design contract completed in `docs/security/ble-security-contract.md`; Phase 0 SDK-only policy/capability/decision scaffolding and legacy-compatible diagnostics are in place; critical command classification now covers SOS trigger/cancel, shutdown, and reboot. | BLE critical writes are still not guaranteed authenticated/encrypted end to end; firmware GATT permissions and secure-link enforcement are required for full fix. | Use the Phase 0 scaffolding to support firmware/protocol planning; do not enable breaking secure-link enforcement until firmware capability exists. |
| SEC-BLE-2 | Partially mitigated SDK/App | SDK | Critical | Design contract defines a versioned command frame with counter/nonce and MAC/auth tag; SDK Phase 0 reserves stable BLE auth/replay/pairing error codes and keeps legacy diagnostics explicit. | Current command writes remain legacy raw opcodes; firmware must verify authenticated frames before command side effects. | Prepare frame encoder/test-vector work behind capability flags, but do not enable until firmware supports verification. |
| SEC-BLE-3 | Partially mitigated SDK/App | SDK+app | High | SDK/app guardrails avoid trusting backend/history-only authority as local SOS authority; Android native classifier treats metadata-only identity as insufficient proof; Phase 0 reserves unverified BLE identity error semantics. | Own-vs-relay BLE identity still ultimately depends on plaintext `nodeId` until firmware/protocol authenticates origin identity. | Keep unknown/unverified identity conservative and wire stronger behavior only after authenticated identity capability exists. |
| SEC-BLE-4 | Partially mitigated SDK/App | SDK | High | SDK/native runtimes have operational dedup windows and lifecycle/cycle suppression to avoid repeated local handling; Phase 0 keeps replay-related diagnostics and error-code reservations available for future secure frames. | Exact-byte/time-window dedup is not cryptographic replay protection. Firmware/protocol counters or nonces are required. | Define firmware-backed replay diagnostics and tests for secure frames; avoid presenting current dedup as replay protection. |
| SEC-BLE-5 | Partially mitigated SDK/App | SDK | High | Design contract states the current `pair(pairingCode)` only validates length and must not be treated as cryptographic pairing; Phase 0 reserves pairing-required error semantics without changing legacy behavior. | Pairing code is still not used as a secret/verifier; firmware/device handshake and secure key storage are required. | Do not claim secure pairing before firmware support exists; plan pairing/auth handshake with firmware constraints. |

## Design-Only Findings

| Finding id | Classification | Repo scope | Risk level | What has been done | What remains | Next recommended action |
| --- | --- | --- | --- | --- | --- | --- |
| SEC-BLE-DESIGN | Design-only | SDK | High | Added `docs/security/ble-security-contract.md` covering current flow, enforcement points, phases 0-4, command frame, pairing, errors, compatibility, tests, and required firmware/SDK changes. | The design document itself does not provide full SEC-BLE remediation. Full remediation requires firmware/protocol support. | Keep the contract aligned with Phase 0 SDK scaffolding and use it for separate firmware/protocol implementation tickets. |
| SDK-APP-TRACKER | Design-only | SDK | Medium | This tracker classifies completed, partial, blocked, and design-only findings under the SDK/app-only boundary. | It must be maintained as audit scope changes. | Update this document before starting implementation work in a new remediation phase. |
| LOCAL-STORAGE-INVENTORY | Design-only | SDK+app | Medium | Added `docs/audit/local-storage-security-inventory.md` to inventory SharedPreferences keys, sensitivity, mitigations, and secure-storage next actions. | Inventory does not move secrets by itself. | Use it as input to the secure storage abstraction design pass. |
| SEC-STORAGE-ABSTRACTION-DESIGN | Phase 2B guardrails complete | SDK+app | High | Added `docs/audit/secure-storage-abstraction-plan.md` covering current mitigations, inspection results, `SecureKeyValueStore` responsibilities/non-goals, key namespaces, candidate key classification, migration strategy, cleanup paths, fallback behavior, iOS Keychain / Android Keystore considerations, test plan, rollout phases, risks, and blocked decisions. Added the SDK core abstraction and fake/unavailable implementations with focused tests. Added the app auth-session config seam and Phase 2B fallback/kill-switch guardrail tests without enabling migration. | No secure-storage dependency, platform-backed implementation, enabled production auth/session migration, or user-data migration exists yet. | Use this as the basis for manual Android/iOS login/session QA and a later dependency/platform decision; do not treat Phase 2B as secure-storage rollout. |
| SEC-NET-INVENTORY | Design-only | SDK+app | High | Added `docs/audit/network-security-hardening-inventory.md` to inventory API endpoint validation, MQTT/WebSocket endpoint validation, SOS trigger transport policy, HTTP cancel/read-only behavior, MQTT lifecycle authority, auth header/token handling, diagnostics redaction, and local/secure-storage interaction. | Inventory does not implement certificate pinning, broker credential rotation, backend token refresh/rotation policy, real secure storage, platform TLS trust changes, backend authorization, or remote relay/LoRa QA. | Use the inventory to select the next safe SEC-NET implementation without overclaiming backend/platform work. |

## Findings Blocked By Firmware/Backend

These are not fixed in the SDK/app boundary.

| Finding id | Classification | Repo scope | Risk level | What has been done | What remains | Next recommended action |
| --- | --- | --- | --- | --- | --- | --- |
| SEC-BLE-1 full fix | Blocked by firmware/backend | firmware/protocol | Critical | SDK design inventory and Phase 0 scaffolding identify command writers, critical opcodes, capability states, and legacy diagnostics. | Firmware must require authenticated encrypted pairing/bonding for critical GATT writes and reject unauthenticated writes. | Open firmware/protocol remediation ticket with the GATT permission and capability-version requirements from the BLE security contract. |
| SEC-BLE-2 full fix | Blocked by firmware/backend | firmware/protocol | Critical | SDK design proposes secure command frame fields and replay rules; SDK Phase 0 reserves stable auth/replay error codes. | Firmware must implement MAC/auth-tag verification before executing commands. | Produce cross-platform test vectors once firmware primitive is selected. |
| SEC-BLE-3 full fix | Blocked by firmware/backend | firmware/protocol | High | SDK/app guardrails and Phase 0 diagnostics reduce unsafe local authority decisions. | Firmware/mesh protocol must authenticate node identity and relay origin. | Define authenticated origin proof for TEL/SOS/event and relay payloads. |
| SEC-BLE-4 full fix | Blocked by firmware/backend | firmware/protocol | High | SDK dedup reduces duplicate processing only; replay rejection remains planned through diagnostics/error scaffolding. | Firmware/protocol must maintain monotonic counters, nonce windows, or equivalent replay rejection. | Pair replay policy with command frame design and persistent counter storage. |
| SEC-BLE-5 full fix | Blocked by firmware/backend | firmware/protocol | High | SDK design states pairing-code semantics and key derivation goals; pairing-required errors are reserved for future enforcement. | Firmware must implement pairing-code-backed authentication, key creation, key rotation, and reset behavior. | Choose pairing primitive with firmware constraints, preferably PAKE or an explicitly documented fallback. |
| SEC-FW | Blocked by firmware/backend | firmware/release pipeline | High | SDK/app tracker records the boundary and does not claim firmware remediation. | Firmware fixes and release-pipeline validation are required outside this remediation scope. | Track in the firmware/release queue; do not modify firmware from this SDK/app-only pass. |
| BACKEND-AUTHZ-SERVER | Blocked by firmware/backend | backend/server | High | SDK/app now gate local authority and redact diagnostics. | Server-side authorization, topic enforcement, backend incident authority, and backend relay validation cannot be proven from SDK/app changes alone. | Track in backend audit queue; do not modify backend from this remediation boundary. |
| SEC-NET-PINNING-TLS | Blocked by backend/platform | platform/native/infrastructure | High | SDK/app now reject insecure endpoint schemes outside debug-local overrides and MQTT bad-certificate callbacks reject invalid certificates. | Certificate pinning is not implemented; TLS trust remains platform/default-library trust unless a later native/platform review proves otherwise. | Decide whether pinning/custom trust is required for HTTP and MQTT, then design platform impact before implementation. |
| SEC-NET-CREDENTIAL-ROTATION | Blocked by backend/platform | backend/broker | High | SDK/app currently pass existing Bearer/userHash and MQTT username/password material through the established backend contract. | Broker credential rotation and backend token refresh/rotation policy are not addressed in this SDK/app pass. | Open backend/broker follow-up for token lifetime, refresh/rotation policy, broker credentials, and topic ACLs. |

## Recommended Next Execution Order

1. SEC-BLE firmware/protocol remediation planning.
   - Treat SDK Phase 0 as completed partial mitigation only.
   - Use the BLE security contract and Phase 0 diagnostics/errors as inputs for firmware GATT permissions, secure command frames, authenticated pairing, replay rejection, and authenticated identity.
   - Keep behavior firmware-compatible until firmware capability is available.

2. Remaining typed runtime boundary cleanup.
   - Keep ARCH-APP-5.3 marked strongly mitigated app-side.
   - Track remaining `LiveEixamSdkClient` dynamic runtime seam work as future work, not fixed.
   - Preserve the completed ARCH-SDK-2 public SOS stream boundary cleanup: keep public state writes centralized, keep bypasses on explicit allow-lists, and do not broaden the retained authoritative bypass classes.
   - Keep app code thin and SDK API-driven.

3. Secure storage abstraction design.
   - Status: Phase 1 abstraction complete in SDK core, Phase 2A app config seam complete in the app, and Phase 2B fallback/kill-switch guardrails complete; real secure storage migration is not fixed.
   - Expanded Android manual QA passed for Auth/session, SOS without device, Devices/BLE, SOS with connected device, and Background/resume in the checkpoint below; iOS manual QA remains needed before any rollout decision.
   - Then decide whether to add a real platform secure-storage dependency behind the existing disabled flag.
   - Only after that dependency/platform decision should Phase 3 app token/session migration be considered.

4. QA gate maintenance.
   - Keep app repository/adapter/smoke/session/config/diagnostics coverage, SDK core secure storage/SOS state-machine coverage, and SDK Flutter SOS lifecycle, MQTT authority, relay handoff, BLE security, transport security, diagnostics redaction, and session-store coverage in the current QA gate list.
   - Treat the aggregate QA list below as passed before this docs-only checkpoint; do not use this checkpoint as approval to rerun tests during docs-only updates.
   - Treat the expanded Android manual QA checkpoint below as app-device coverage for the listed cases only; remote relay/LoRa was not tested in this round and is not release-ready evidence. iOS QA remains deferred to final acceptance.

5. Firmware/backend-blocked items documented for later.
   - SEC-BLE full remediation requires firmware/protocol support.
   - SEC-FW requires firmware/release pipeline work.
   - Backend/server authorization and authority guarantees stay in the backend audit queue.

6. SEC-NET next implementation decision.
   - Use `docs/audit/network-security-hardening-inventory.md` as the source inventory.
   - Do not claim certificate pinning, custom TLS trust, broker credential rotation, backend token policy, real secure storage, or remote relay/LoRa QA as fixed.
   - First safe decision points are MQTT WebSocket TLS confirmation, pinning/custom trust design, backend/broker rotation and ACL tickets, secure-storage dependency approval, and dedicated remote relay/LoRa manual QA.

## Boundary Notes

- SEC-BLE design contract is completed, but SEC-BLE is not fully fixed.
- Full SEC-BLE remediation requires firmware/protocol support for authenticated BLE links, command integrity, cryptographic pairing, replay rejection, and authenticated node/relay identity.
- SDK-only SEC-BLE Phase 0 is completed partial mitigation: diagnostics, capability modeling, command criticality, and public-error scaffolding are in place without breaking unsupported firmware.
- SEC-FW is blocked by firmware/release pipeline work.
- Secure storage migration is designed/planned, Phase 1 abstraction is complete, Phase 2A feature/config seam is complete, and Phase 2B fallback/kill-switch guardrails are complete, but real secure storage is not fixed because no secure-storage dependency, platform-backed implementation, enabled flag, token/session migration, or user-data migration exists yet.
- Backend/server must participate for server-side authorization and backend-owned lifecycle authority guarantees.
- SEC-NET inventory is documentation-only. Certificate pinning is not implemented, broker credential rotation is not addressed, backend token refresh/rotation policy is not addressed, real secure storage is not added or enabled, TLS trust remains platform/default-library trust unless separately proven, and remote relay/LoRa manual QA is deferred.

## Manual QA Checkpoint - Android Expanded

Date: 2026-06-27

Scope: Expanded Android manual QA after the SDK/app audit remediation and guardrails checklist. This checkpoint records observed Android app-device behavior only; it does not change the automated QA gate list, does not cover remote relay/LoRa, does not complete iOS acceptance, and does not claim release readiness.

| Case | Result | Notes |
| --- | --- | --- |
| Auth/session | PASS | Authentication and session behavior passed on Android. |
| SOS without device | PASS | SOS flow without a connected device passed on Android. |
| Devices/BLE | PASS | Devices and BLE behavior passed on Android. |
| SOS with connected device | PASS | SOS flow with a connected device passed on Android. |
| Background/resume | PASS | Background and resume behavior passed on Android. |
| Remote relay / LoRa | Not tested | Not tested in this round; still requires dedicated manual QA before it can be used as release evidence. |
| iOS QA | Deferred | Deferred to final acceptance; not covered by this Android checkpoint. |

Checkpoint constraints:

- This expanded checkpoint covers only the five passed Android cases listed above.
- Remote relay/LoRa manual QA was not tested in this round and must not be treated as passed.
- iOS QA remains deferred to final acceptance.
- SEC-BLE full remediation remains blocked by firmware/protocol support for authenticated BLE links, command integrity, cryptographic pairing, replay rejection, and authenticated node/relay identity.
- Secure storage real migration remains pending: there is still no secure-storage dependency, platform-backed implementation, enabled flag, real token/session migration, or user-data migration.
- Backend/server authorization and backend-owned lifecycle authority guarantees remain outside this SDK/app-only checkpoint.

## Manual QA Checkpoint - Android Previous

Date: 2026-06-25

Scope: Android manual QA after the recent SDK/app audit remediation work. This checkpoint records observed app-device behavior only; it does not change the automated QA gate list and does not claim release readiness for unresolved firmware/backend-blocked items.

| Case | Result | Notes |
| --- | --- | --- |
| Login / session restore | PASS | Login and restored session behavior passed on Android. |
| Logout / session cleanup | PASS | Logout, reopen, and return to login screen passed on Android. |
| SOS without device | PASS | SOS flow without a connected device passed on Android. |
| Devices / BLE basic | PASS | Basic devices/BLE behavior passed on Android. |
| SOS with connected device | PASS | SOS flow with a connected device passed on Android. |
| Remote relay / LoRa | Deferred / not tested | Not passed in this checkpoint; still requires dedicated manual QA before it can be used as release evidence. |

Checkpoint constraints:

- SEC-BLE full remediation remains blocked by firmware/protocol support for authenticated BLE links, command integrity, cryptographic pairing, replay rejection, and authenticated node/relay identity.
- Secure storage real migration remains pending: there is still no secure-storage dependency, platform-backed implementation, enabled flag, real token/session migration, or user-data migration.
- Backend/server authorization and backend-owned lifecycle authority guarantees remain outside this SDK/app-only checkpoint.

## Current QA Gate List

These tests are the current audit checkpoint QA gate list. They passed before this docs-only checkpoint; this docs-only update did not rerun tests.

Most recent ARCH-SDK-2 second-pass validation recorded before this docs update:

- `dart format` on touched SDK files.
- `dart analyze` on touched SDK files with only the existing `implementation_imports` info.
- `cd packages/eixam_connect_core && dart test test/state/sos_state_machine_test.dart -r expanded`
- `cd packages/eixam_connect_flutter && flutter test test/sdk/sos_lifecycle_matrix_test.dart --concurrency=1 -r expanded`
- `cd packages/eixam_connect_flutter && flutter test test/sdk/remote_relay_sos_backend_handoff_test.dart --concurrency=1 -r expanded`
- `git diff --check`
- Only intended SDK files were modified during the ARCH-SDK-2 implementation pass.

App:

- `live_eixam_sdk_client_test`
- `partner_sdk_adapter_test`
- `smoke_test`
- `shared_preferences_auth_session_store_test`
- `secure_storage_backed_auth_session_store_test`
- `app_config_test`
- `session_controller_test`
- `app_diagnostics_redactor_test`

SDK core:

- `secure_key_value_store_test`
- `sos_state_machine_test`

SDK Flutter:

- `sos_lifecycle_matrix_test`
- `mqtt_operational_sos_repository_lifecycle_authority_test`
- `remote_relay_sos_backend_handoff_test`
- `ble_security_policy_test`
- `eixam_ble_command_test`
- `transport_security_validator_test`
- `security_diagnostics_redactor_test`
- `sdk_session_store_test`
