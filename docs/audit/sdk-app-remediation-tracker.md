# SDK/App Audit Remediation Tracker

Status: SDK/app-only planning tracker for Dani audit remediation.

This tracker is intentionally scoped to:

- SDK: `/Users/roger/flutterdev/eixam-sdk-flutter`
- App: `/Users/roger/flutterdev/eixam_commecial_app/eixam-app`

Do not use this tracker as approval to change backend, firmware, protocol server code, generated files, or `build/test_cache`. Firmware/backend-required findings below are not fixed unless explicitly marked fixed by a later firmware/backend remediation pass.

## Completed SDK/App Mitigations

| Finding id | Status | Repo scope | Risk level | What has been done | What remains | Next recommended action |
| --- | --- | --- | --- | --- | --- | --- |
| SOS-AUTH-META | Fixed / already mitigated | SDK | High | SDK incidents now carry typed SOS authority metadata so app consumers can distinguish SDK-owned/local-actionable SOS from external/backend-only records. | Continue preserving typed authority as the source of truth. | Add regression coverage whenever incident mapping changes. |
| APP-SOS-AUTH-FALLBACK | Fixed / already mitigated | app | High | App applies conservative fallback when typed SDK SOS authority is missing, treating the incident as external/history-only instead of active local authority. | Backend history without SDK authority still cannot become local-actionable from app logic alone. | Keep app fallback conservative; do not reintroduce app-side lifecycle authority. |
| TEST-2 | Fixed / already mitigated | SDK | Medium | `SosStateMachine` lifecycle coverage exists for SDK state transitions and edge cases. | Coverage must be extended with any new lifecycle behavior. | Keep targeted state-machine tests close to future SOS lifecycle changes. |
| APP-SOS-SYNTHETIC | Fixed / already mitigated | app | High | App synthetic SOS sending was removed, so UI no longer fabricates sending/active state outside SDK authority. | App still depends on SDK state fidelity. | Preserve thin-app rule: render SDK state, do not recreate SOS state machines in widgets/repositories. |
| SOS-DEV-1 | Fixed / already mitigated | SDK | High | Remote relay handoff now has dedup/fail-safe behavior so duplicate relay backend handoffs are constrained. | Cryptographic relay origin proof is not provided by this SDK-only fix. | Keep relay retry/dedup SDK-owned; defer authenticated relay origin to SEC-BLE/protocol work. |
| ARCH-APP-3 / SOS-REPO-12 | Fixed / already mitigated | SDK+app | High | Guardrails keep SOS orchestration, relay routing, and raw BLE handling in SDK/runtime layers rather than app widgets. | Future app changes can regress this boundary. | Enforce via review: app may call typed SDK APIs only. |
| SOS-REPO-12.1 | Fixed / already mitigated | app | High | App guards are identity-bounded, preventing backend/history snapshots without SDK authority from recreating local active SOS. | Does not authenticate BLE node identity. | Keep repository guards tied to SDK authority and known identity evidence. |
| SEC-NET-3 | Fixed / already mitigated | SDK | High | MQTT lifecycle authority gate prevents unrelated realtime/backend lifecycle events from taking local SOS authority. | Backend/server authorization is outside this SDK/app boundary. | Preserve topic/session authority checks during realtime refactors. |
| SEC-NET-LOCAL-STORAGE | Partially mitigated | SDK+app | High | Added `docs/audit/local-storage-security-inventory.md`; reduced app telemetry persistence from a 64-entry location history to latest-only; blocked auth-looking strings from app telemetry persistence; cleared orphan app auth fragments when restore cannot authenticate; stopped new SDK session writes from persisting the unused SDK refresh token while keeping legacy reads compatible. | App auth tokens, SDK signed identity, location/SOS/DMP/device/contact state still use SharedPreferences because no secure-storage dependency/abstraction exists in this pass. | Move highest-risk auth/session secrets to secure storage in a dedicated dependency-approved pass; keep backend auth format unchanged. |
| SOS-SDK-1 | Fixed / already mitigated | SDK | High | SDK supports device-only SOS success when backend is unavailable but a valid device SOS path succeeds. | Device command path security remains subject to SEC-BLE limitations. | Keep one-successful-channel semantics covered by SDK tests. |
| SEC-DIAG-PII | Fixed / already mitigated | SDK+app | Medium | Sensitive diagnostics and PII redaction were added for SDK/app logs, raw payloads, identity values, topics, headers, and payload bodies. | New diagnostic fields can reintroduce sensitive data if not routed through redactors. | Require redaction review for all new diagnostics. |

## Remaining SDK/App-Fixable Findings

No fully SDK/app-fixable open finding is identified from the currently available local docs and completed-work list.

If new audit rows are added, classify them here only when the complete remediation can be delivered without firmware, backend, protocol, or server changes.

| Finding id | Status | Repo scope | Risk level | What has been done | What remains | Next recommended action |
| --- | --- | --- | --- | --- | --- | --- |
| None currently identified | Not applicable | SDK/app | Not applicable | Current known remaining security issues require at least partial firmware/backend/protocol participation. | Keep this section current as new audit rows are triaged. | Add only complete SDK/app fixes here. |

## Remaining SDK/App-Partial Findings

These findings can be reduced from SDK/app, but cannot be fully fixed in the current boundary. Do not mark them fixed until the blocked firmware/backend/protocol work is complete.

| Finding id | Status | Repo scope | Risk level | What has been done | What remains | Next recommended action |
| --- | --- | --- | --- | --- | --- | --- |
| SEC-BLE-1 | Partially mitigable from SDK/app | SDK | Critical | Design contract completed in `docs/security/ble-security-contract.md`; current Android paths already check some system bond presence on reconnect/protection paths. | BLE critical writes are still not guaranteed authenticated/encrypted end to end; firmware GATT permissions and secure-link enforcement are required for full fix. | SDK/app next: add capability diagnostics and, later, write-time critical-command gates where platform evidence exists. |
| SEC-BLE-2 | Partially mitigable from SDK/app | SDK | Critical | Design contract defines a versioned command frame with counter/nonce and MAC/auth tag. | Current command writes are raw opcodes; firmware must verify authenticated frames before command side effects. | SDK/app next: prepare frame encoder/test vectors behind capability flags, but do not enable until firmware supports verification. |
| SEC-BLE-3 | Partially mitigable from SDK/app | SDK+app | High | SDK/app guardrails now avoid trusting backend/history-only authority as local SOS authority; Android native classifier treats metadata-only identity as insufficient proof. | Own-vs-relay BLE identity still ultimately depends on plaintext `nodeId` until firmware/protocol authenticates origin identity. | SDK/app next: keep unknown/unverified identity conservative and add `E_BLE_DEVICE_ID_UNVERIFIED` once public errors are implemented. |
| SEC-BLE-4 | Partially mitigable from SDK/app | SDK | High | SDK/native runtimes have operational dedup windows and lifecycle/cycle suppression to avoid repeated local handling. | Exact-byte/time-window dedup is not cryptographic replay protection. Firmware/protocol counters or nonces are required. | SDK/app next: define replay diagnostics and tests for future secure frames; avoid presenting current dedup as replay protection. |
| SEC-BLE-5 | Partially mitigable from SDK/app | SDK | High | Design contract states the current `pair(pairingCode)` only validates length and must not be treated as cryptographic pairing. | Pairing code is still not used as a secret/verifier; firmware/device handshake and secure key storage are required. | SDK/app next: add capability/error planning for `E_BLE_PAIRING_REQUIRED`; do not claim secure pairing before firmware support exists. |

## Findings Blocked By Firmware/Backend

These are not fixed in the SDK/app boundary.

| Finding id | Status | Repo scope | Risk level | What has been done | What remains | Next recommended action |
| --- | --- | --- | --- | --- | --- | --- |
| SEC-BLE-1 full fix | Blocked by firmware/protocol | blocked | Critical | SDK design inventory identifies command writers and critical opcodes. | Firmware must require authenticated encrypted pairing/bonding for critical GATT writes and reject unauthenticated writes. | Open firmware/protocol remediation ticket with the GATT permission and capability-version requirements from the BLE security contract. |
| SEC-BLE-2 full fix | Blocked by firmware/protocol | blocked | Critical | SDK design proposes secure command frame fields and replay rules. | Firmware must implement MAC/auth-tag verification before executing commands. | Produce cross-platform test vectors once firmware primitive is selected. |
| SEC-BLE-3 full fix | Blocked by firmware/protocol | blocked | High | SDK/app guardrails reduce unsafe local authority decisions. | Firmware/mesh protocol must authenticate node identity and relay origin. | Define authenticated origin proof for TEL/SOS/event and relay payloads. |
| SEC-BLE-4 full fix | Blocked by firmware/protocol | blocked | High | SDK dedup reduces duplicate processing only. | Firmware/protocol must maintain monotonic counters, nonce windows, or equivalent replay rejection. | Pair replay policy with command frame design and persistent counter storage. |
| SEC-BLE-5 full fix | Blocked by firmware/protocol | blocked | High | SDK design states pairing-code semantics and key derivation goals. | Firmware must implement pairing-code-backed authentication, key creation, key rotation, and reset behavior. | Choose pairing primitive with firmware constraints, preferably PAKE or an explicitly documented fallback. |
| BACKEND-AUTHZ-SERVER | Blocked by backend/server | blocked | High | SDK/app now gate local authority and redact diagnostics. | Server-side authorization, topic enforcement, backend incident authority, and backend relay validation cannot be proven from SDK/app changes alone. | Track in backend audit queue; do not modify backend from this remediation boundary. |

## Documentation/Design-Only Findings

| Finding id | Status | Repo scope | Risk level | What has been done | What remains | Next recommended action |
| --- | --- | --- | --- | --- | --- | --- |
| SEC-BLE-DESIGN | Documentation/design-only completed | SDK | High | Added `docs/security/ble-security-contract.md` covering current flow, enforcement points, phases 0-4, command frame, pairing, errors, compatibility, tests, and required firmware/SDK changes. | Runtime behavior is intentionally unchanged; SEC-BLE is not fixed. | Use the design contract as the input to separate SDK partial-mitigation and firmware/protocol implementation tickets. |
| SDK-APP-TRACKER | Documentation/design-only completed | SDK | Medium | This tracker classifies completed, fixable, partial, blocked, and design-only findings under the SDK/app-only boundary. | It must be maintained as audit scope changes. | Update this document before starting implementation work in a new remediation phase. |

## Recommended Execution Order

1. Preserve completed mitigations.
   - Treat authority metadata, app conservative fallback, relay dedup, MQTT lifecycle authority, device-only success, and redaction as regression-sensitive.
   - Do not move SDK-owned SOS, BLE, or relay logic into app code.

2. Convert SEC-BLE design into SDK-only safe groundwork.
   - Add diagnostics/capability modeling first.
   - Add public error planning for `E_BLE_LINK_NOT_SECURE`, `E_BLE_PAIRING_REQUIRED`, `E_BLE_COMMAND_AUTH_FAILED`, `E_BLE_REPLAY_REJECTED`, and `E_BLE_DEVICE_ID_UNVERIFIED`.
   - Keep behavior guarded by feature/capability flags.

3. Add SDK/app partial gates only where they fail closed without breaking unsupported firmware unexpectedly.
   - Critical-command write gates should be capability-aware.
   - Android/iOS native protection command paths must match Dart policy.

4. Create separate firmware/protocol tickets for SEC-BLE full fixes.
   - GATT security permissions.
   - Pairing/auth handshake.
   - Command MAC/counter verification.
   - Authenticated node and relay identity.

5. Create separate backend/server tickets only for backend-owned findings.
   - Server authorization, topic validation, backend incident authority, and relay acceptance rules are outside this SDK/app pass.

6. After firmware/backend capability exists, return to SDK implementation.
   - Enable secure frames by advertised capability version.
   - Add replay/MAC/identity tests before enabling critical-command enforcement broadly.

## Boundary Notes

- SEC-BLE is design-complete only. It is not fixed.
- SDK/app can reduce unsafe decisions, improve diagnostics, add public errors, and prepare capability-gated frame logic.
- Firmware/protocol must participate for authenticated BLE links, command integrity, cryptographic pairing, replay rejection, and authenticated node/relay identity.
- Backend/server must participate for server-side authorization and backend-owned lifecycle authority guarantees.
