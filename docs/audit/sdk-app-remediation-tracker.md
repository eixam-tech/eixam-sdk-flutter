# SDK/App Audit Remediation Tracker

Status: SDK/app-only checkpoint for Dani audit remediation after SEC-BLE Phase 0 SDK-only scaffolding, ARCH-APP-5 second pass, and remote relay SOS test-debt cleanup.

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
- ARCH-APP-5 typed SDK boundary second pass is complete and strongly mitigated app-side: the SOS adapter path uses `SdkSosSnapshot`, remaining remote-relay SDK event dynamic access is centralized behind `_legacySdkEventStream()`, and `LiveEixamSdkClient` typed runtime seam work remains future scope.
- ARCH-SDK-2 public SOS stream guard first pass is complete; cleanup remains.
- Remote relay SOS test-debt cleanup is complete: stale decoder expectations, HTTP-era assertions, active-device PRE-SOS countdown behavior, and correlated backend cancel setup are aligned with current SDK behavior.
- SEC-NET endpoint hardening is complete for the SDK/app boundary.
- Local storage hardening is partially mitigated: app auth orphan fragments are cleaned up, telemetry is latest-only, telemetry auth-token/header persistence is blocked, the SDK no longer writes the unused refresh token, and the local-storage security inventory is documented.
- Secure storage migration is now designed/planned in `docs/audit/secure-storage-abstraction-plan.md`; Phase 1 adds a pure Dart SDK core abstraction, but it is not fixed because no secure-storage dependency, platform-backed implementation, or runtime migration exists yet.

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
| SEC-NET-ENDPOINT | Strongly mitigated SDK/App | SDK+app | High | Endpoint handling was hardened within the SDK/app boundary so callers use the intended configured endpoints and avoid unsafe endpoint drift. | Server-side endpoint authorization and infrastructure controls remain backend-owned. | Preserve centralized endpoint construction and review any future dynamic endpoint inputs. |
| SOS-SDK-1 | Fixed SDK/App | SDK | High | SDK supports device-only SOS success when backend is unavailable but a valid device SOS path succeeds. | Device command path security remains subject to SEC-BLE limitations. | Keep one-successful-channel semantics covered by SDK tests. |
| SEC-DIAG-PII | Fixed SDK/App | SDK+app | Medium | Sensitive diagnostics and PII redaction were added for SDK/app logs, raw payloads, identity values, topics, headers, and payload bodies. | New diagnostic fields can reintroduce sensitive data if not routed through redactors. | Require redaction review for all new diagnostics. |
| ARCH-APP-5 | Strongly mitigated SDK/App | app | Medium | Typed SDK boundary second pass is complete in `partner_sdk_adapter.dart`: the SOS adapter path now uses `SdkSosSnapshot`, and remaining remote-relay SDK event dynamic access is centralized behind `_legacySdkEventStream()`. | `LiveEixamSdkClient` still has documented dynamic runtime seam work that belongs to a larger future pass. | Keep app code on typed SDK APIs and plan the `LiveEixamSdkClient` seam separately; do not claim dynamic access is fully eliminated. |
| ARCH-SDK-2 | Strongly mitigated SDK/App | SDK | Medium | Public SOS stream guard first pass is complete, keeping public stream consumers aligned to guarded SDK state. | Remaining public-boundary cleanup and regression coverage may still be needed. | Continue cleanup in a dedicated public-boundary pass. |
| REMOTE-RELAY-SOS-TEST-DEBT | Fixed SDK/App | SDK tests | Medium | `remote_relay_sos_backend_handoff_test.dart` now matches current decoder output, MQTT contract/repository paths, active-device PRE-SOS countdown promotion, and backend cancel correlation requirements. The remote relay SOS handoff test debt is cleaned up without runtime behavior changes. | Continue keeping relay tests aligned to SDK contract changes. | Keep this test in the QA gate list for future relay/SOS work. |

## Partial SDK/App Mitigations

These findings are reduced from SDK/app, but they are not fully fixed in the current boundary.

| Finding id | Classification | Repo scope | Risk level | What has been done | What remains | Next recommended action |
| --- | --- | --- | --- | --- | --- | --- |
| SEC-NET-LOCAL-STORAGE | Partially mitigated SDK/App | SDK+app | High | Added `docs/audit/local-storage-security-inventory.md`; reduced app telemetry persistence from a 64-entry location history to latest-only; blocked auth-looking strings from app telemetry persistence; cleared orphan app auth fragments when restore cannot authenticate; stopped new SDK session writes from persisting the unused SDK refresh token while keeping legacy reads compatible; added Phase 1 SDK core secure key-value abstraction and fake/unavailable implementations. | App auth tokens, SDK signed identity, location/SOS/DMP/device/contact state still use SharedPreferences because no secure-storage dependency, platform-backed implementation, or runtime migration exists in this pass. | Approve the secure-storage dependency/platform policy before moving highest-risk auth/session secrets; keep backend auth format unchanged. |
| SEC-STORAGE-SECURE-MIGRATION | Partially mitigated SDK/App | SDK+app | High | Secure-storage migration is designed/planned in `docs/audit/secure-storage-abstraction-plan.md`: it defines `SecureKeyValueStore`, candidate key classification, SharedPreferences migration strategy, logout/session cleanup, fallback behavior, platform considerations, tests, risks, blocked decisions, and phases 0-4. Phase 1 now adds the pure Dart SDK core abstraction, in-memory test store, unavailable store, stable key namespace helpers, and focused unit tests. | It is not fixed: no secure-storage dependency has been added, no platform-backed implementation exists, no data has migrated, and app auth tokens plus SDK signed identity still use SharedPreferences today. | Treat Phase 2 as the next implementation candidate after dependency/platform decisions: app auth behind a feature flag, then SDK session migration. |
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
| SEC-STORAGE-ABSTRACTION-DESIGN | Phase 1 complete | SDK+app | High | Added `docs/audit/secure-storage-abstraction-plan.md` covering current mitigations, inspection results, `SecureKeyValueStore` responsibilities/non-goals, key namespaces, candidate key classification, migration strategy, cleanup paths, fallback behavior, iOS Keychain / Android Keystore considerations, test plan, rollout phases, risks, and blocked decisions. Added the SDK core abstraction and fake/unavailable implementations with focused tests. | No secure-storage dependency, platform-backed implementation, production auth/session wiring, feature flag, or user-data migration exists yet. | Use this as the basis for Phase 2 app auth migration behind a feature flag after dependency/platform decisions. |

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

## Recommended Next Execution Order

1. SEC-BLE firmware/protocol remediation planning.
   - Treat SDK Phase 0 as completed partial mitigation only.
   - Use the BLE security contract and Phase 0 diagnostics/errors as inputs for firmware GATT permissions, secure command frames, authenticated pairing, replay rejection, and authenticated identity.
   - Keep behavior firmware-compatible until firmware capability is available.

2. Remaining typed runtime boundary cleanup.
   - Keep ARCH-APP-5 second pass marked strongly mitigated app-side.
   - Track `LiveEixamSdkClient` dynamic runtime seam as future work, not fixed.
   - Continue ARCH-SDK-2 public SOS stream guard cleanup.
   - Keep app code thin and SDK API-driven.

3. Secure storage abstraction design.
   - Status: Phase 1 abstraction complete in SDK core and documented in `docs/audit/secure-storage-abstraction-plan.md`; real secure storage migration is not fixed.
   - Next implementation candidate: Phase 2 app auth migration behind a feature flag.
   - Choose or approve a secure-storage dependency/platform policy before moving app auth tokens or SDK signed identity.

4. QA gate maintenance.
   - Keep SOS lifecycle, MQTT lifecycle authority, remote relay SOS handoff, BLE security policy/command, diagnostics redaction, session store, and smoke coverage in the current QA gate list.
   - Do not use this checkpoint as approval to run tests during this docs-only update.

5. Firmware/backend-blocked items documented for later.
   - SEC-BLE full remediation requires firmware/protocol support.
   - SEC-FW requires firmware/release pipeline work.
   - Backend/server authorization and authority guarantees stay in the backend audit queue.

## Boundary Notes

- SEC-BLE design contract is completed, but SEC-BLE is not fully fixed.
- Full SEC-BLE remediation requires firmware/protocol support for authenticated BLE links, command integrity, cryptographic pairing, replay rejection, and authenticated node/relay identity.
- SDK-only SEC-BLE Phase 0 is completed partial mitigation: diagnostics, capability modeling, command criticality, and public-error scaffolding are in place without breaking unsupported firmware.
- SEC-FW is blocked by firmware/release pipeline work.
- Secure storage migration is designed/planned and Phase 1 abstraction is complete, but real secure storage is not fixed because no secure-storage dependency, platform-backed implementation, feature flag, or user-data migration exists yet.
- Backend/server must participate for server-side authorization and backend-owned lifecycle authority guarantees.

## Current QA Gate List

These tests are the current audit checkpoint QA gate list. This docs-only update does not claim they were run in this pass.

- `sos_lifecycle_matrix_test`
- `mqtt_operational_sos_repository_lifecycle_authority_test`
- `remote_relay_sos_backend_handoff_test`
- `ble_security_policy_test`
- `eixam_ble_command_test`
- `transport_security_validator_test`
- `security_diagnostics_redactor_test`
- `sdk_session_store_test`
- `smoke_test`
