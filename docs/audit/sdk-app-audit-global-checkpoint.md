# SDK/App Audit Global Checkpoint

Date: 2026-06-25

Historical checkpoint: retained for audit evidence. The final SOS-first branch
supersedes its lifecycle/persistence description; see
`../SOS_LIFECYCLE_ARCHITECTURE_2026.md`. Backend, firmware, broker, and rollout
gaps are not closed by that supersession.

Scope:

- SDK: this repository
- App reference: the sibling partner-app repository

This checkpoint summarizes the SDK/app audit remediation state after the recent SOS lifecycle, transport, BLE/security, storage, diagnostics, app-architecture, reconnect/readiness, and QA remediation work. It is intentionally honest about what is fixed in the SDK/app boundary and what still requires firmware, backend, platform, or rollout decisions.

Do not use this checkpoint as evidence that backend, firmware, platform-native, generated, or production app/runtime code outside the completed SDK/app remediation scope has been fixed.

## Executive Summary

The SDK/app audit remediation is now materially safer than the starting point, especially around SOS lifecycle authority, public SOS stream state ownership, app-side state ownership, MQTT-only SOS trigger behavior, sensitive diagnostics redaction, endpoint guardrails, local-storage exposure reduction, and typed SDK/app boundary cleanup.

Approximate status:

- Overall audit progress: around 50-55%.
- SOS/life-safety SDK/app risk: strongly reduced, around 85-90%.
- SDK/app-fixable criticals: around 80-85%.
- BLE full security: partial only, because authenticated BLE links, secure command frames, replay rejection, cryptographic pairing, and authenticated node/relay identity require firmware/protocol work.
- Secure storage: partial only, because a real platform secure-storage dependency, enabled rollout flag, migration, and user-data migration are not yet in place.

Most urgent SDK/app risks have either been fixed or strongly mitigated where they were controllable from the SDK/app boundary. Remaining high-risk areas are concentrated in firmware/protocol BLE security, backend/server authorization and broker credential policy, platform TLS/pinning decisions, real secure-storage rollout, and deferred remote relay/LoRa manual QA.

Expanded Android manual QA passed on 2026-06-27 for the listed app-device cases below. This is a checkpoint for those Android cases only; it does not claim remote relay/LoRa coverage, iOS acceptance, or overall release readiness.

## Status Categories

| Category | Meaning |
| --- | --- |
| Fixed SDK/App | Implemented and validated within the SDK/app boundary for the current known behavior. |
| Strongly mitigated SDK/App | Risk is substantially reduced in SDK/app, but some external trust, compatibility, or future regression risk remains. |
| Partially mitigated SDK/App | SDK/app reduced the risk or added rollout scaffolding, but the full fix is not complete. |
| Design-only | Documentation, inventory, or implementation plan exists, but it is not itself a full runtime fix. |
| Blocked by firmware/backend/platform | The remaining fix requires firmware, backend, broker, infrastructure, native platform, or protocol changes outside this scope. |
| Future hardening | Useful next work, but not required to describe the current checkpoint as remediated within scope. |

## Completed SDK/App Mitigations

### Fixed SDK/App

- SDK typed SOS authority metadata is in place.
- App conservative SOS authority fallback prevents backend/history-only incidents from becoming active local SOS without typed SDK authority.
- Public SDK SOS stream state writes are centralized through `_emitPublicSosState` / `_applyPublicSosState`, with canonical transitions still guarded by `SosStateMachine.canTransition(...)`.
- App synthetic `sending` / `active` SOS state has been removed.
- Device-only SOS success is handled correctly when the device path succeeds even if backend is unavailable.
- SOS trigger uses MQTT; HTTP SOS trigger remains blocked.
- HTTP cancel/read-only behavior is preserved.
- Backend handoff dedup for remote relay is recorded only after backend success, so backend failure can retry.
- Sensitive diagnostics redaction is in place for SDK/app logs and diagnostics, including raw BLE hex, identifiers, coordinates, headers, topics, and payload bodies outside debug.
- SDK no longer persists the unused refresh token.
- App auth orphan fragments are cleaned up when restore cannot authenticate.
- App telemetry persistence is reduced to latest-only and blocks auth-looking strings.
- Stale override warnings identified in `LiveEixamSdkClient` were removed without behavior changes.
- Endpoint handling is hardened at the SDK/app boundary for HTTPS/WSS/secure MQTT expectations outside explicit debug-local overrides.

### Strongly Mitigated SDK/App

- SOS lifecycle and local authority are now SDK-owned and guarded by typed authority.
- ARCH-SDK-2 second-pass public SOS stream boundary cleanup is complete and strongly mitigated: direct `_publicSosState` and `_publicSosStateController.add(...)` mutation is centralized, broad source-string bypass predicates were replaced with explicit source allow-lists, and retained bypass diagnostics include `reason`, `authority`, `origin`, and `policy`.
- Retained public SOS transition bypasses are intentional and constrained to authoritative/compatibility classes: repository/backend terminal authority, repository rehydration, device runtime overrides, app-trigger publish shortcut, explicit idle clears, and external/remote-relay isolation clears.
- Backend/open history cannot promote active local SOS without SDK authority.
- External/remote LoRa events remain external/history-only for local UI unless there is valid local SDK authority.
- External/remote relay paths continue to clear or remain idle as `external_remote_relay_isolation`; they do not become local active SOS through the public stream boundary.
- MQTT lifecycle inbound events are authority-gated.
- App compatibility guards are bounded by strong identity evidence.
- Partner SDK adapter typed SOS path is tightened.
- Legacy dynamic SOS authority fallback is centralized.
- `LiveEixamSdkClient` dynamic seams are inventoried and constrained at the injected SDK runtime boundary.
- Remote relay SOS handoff behavior now has passing focused coverage for the current SDK contract.
- Reconnect/readiness SDK/app behavior is validated by focused tests and Android manual QA for the listed cases.

### Partially Mitigated SDK/App

- SEC-BLE Phase 0 SDK-only scaffold is complete: BLE security policy, capability, decision modeling, command criticality, critical command classification, stable diagnostics, and strict-mode scaffolding are present.
- Strict BLE enforcement is not enabled because unsupported firmware/protocol would break compatibility.
- Local storage hardening reduced exposure, but app auth tokens, SDK signed identity, and other sensitive state still use SharedPreferences by default.
- Secure storage has a pure Dart SDK core abstraction, app auth-session seam, disabled-by-default flags, fallback behavior, and kill-switch guardrails.
- Secure storage is not rolled out because no real platform-backed dependency, enabled flag, token/session migration, or user-data migration exists.
- App architecture is cleaner and safer, but `LiveEixamSdkClient` is not fully typed; remaining dynamic runtime boundary work is future scope.

### Design-Only

- `docs/security/ble-security-contract.md` defines the BLE security target contract, phases, command framing, pairing expectations, replay handling, diagnostics, and compatibility constraints.
- `docs/audit/local-storage-security-inventory.md` inventories sensitive local storage and current mitigations.
- `docs/audit/secure-storage-abstraction-plan.md` defines secure-storage migration phases, key classification, fallback behavior, cleanup paths, platform considerations, test plan, risks, and blocked decisions.
- `docs/audit/network-security-hardening-inventory.md` inventories endpoint, MQTT/WebSocket, SOS transport, auth/token, diagnostics, and local/secure-storage interactions.
- `docs/audit/sdk-app-remediation-tracker.md` remains the detailed finding-by-finding tracker.

## QA Status

Automated QA gates passed before this docs-only checkpoint. Tests were not rerun for this checkpoint.

Most recent ARCH-SDK-2 second-pass validation recorded before this docs update:

- `dart format` on touched SDK files.
- `dart analyze` on touched SDK files with only the existing `implementation_imports` info.
- `cd packages/eixam_connect_core && dart test test/state/sos_state_machine_test.dart -r expanded`
- `cd packages/eixam_connect_flutter && flutter test test/sdk/sos_lifecycle_matrix_test.dart --concurrency=1 -r expanded`
- `cd packages/eixam_connect_flutter && flutter test test/sdk/remote_relay_sos_backend_handoff_test.dart --concurrency=1 -r expanded`
- `git diff --check`
- Only intended SDK files were modified during the ARCH-SDK-2 implementation pass.

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
- `ble_auto_reconnect_coordinator_test`

App:

- `live_eixam_sdk_client_test`
- `partner_sdk_adapter_test`
- `smoke_test`
- `shared_preferences_auth_session_store_test`
- `secure_storage_backed_auth_session_store_test`
- `app_config_test`
- `session_controller_test`
- `app_diagnostics_redactor_test`
- `app_shell_test`
- `device_auto_reconnect_coordinator_test`
- `partner_app_repository_reconnect_test`
- `devices_screen_test`
- `runtime_capability_service_repository_test`
- `default_runtime_capability_service_test`
- `home_screen_test`
- `partner_app_repository_sos_sync_test`

## Manual QA Status

Expanded Android manual QA checkpoint:

Date: 2026-06-27

Passed Android cases:

- Auth/session.
- SOS without device.
- Devices/BLE.
- SOS with connected device.
- Background/resume.

Not tested / deferred in this round:

- Remote relay/LoRa manual QA was not tested and must not be treated as passed.
- iOS QA remains deferred to final acceptance.

Previous Android manual QA checkpoint:

Android manual QA passed for:

- Login / session restore.
- Logout / reopen / login screen.
- SOS without device.
- Devices / BLE basic behavior.
- SOS with connected device.

Deferred / not passed:

- Remote relay / LoRa manual QA is deferred and must not be treated as passed.
- iOS manual QA still needs to be completed and recorded for login/session, BLE discovery/connect, and SOS countdown/cancel.

## Deferred Items

- Remote relay / LoRa manual QA when the setup is available.
- iOS manual QA for login/session restore, BLE discovery/connect, and SOS countdown/cancel.
- Real secure-storage dependency decision and implementation behind the existing disabled flag.
- Real token/session migration after platform secure storage is approved and implemented.
- User-data migration for sensitive persisted app/SDK state.
- Remaining `LiveEixamSdkClient` typed runtime seam cleanup.
- Future public SDK SOS stream work should preserve the completed centralized boundary and explicit allow-lists, not broaden retained bypass classes.
- Manual QA expansion after any secure-storage or BLE enforcement rollout.

## Blocked Firmware/Backend/Platform Items

### Blocked by Firmware/Protocol

- BLE critical writes are not fully protected until firmware requires authenticated encrypted pairing/bonding for critical GATT writes.
- BLE command integrity is not fully protected until firmware verifies authenticated command frames before executing command side effects.
- BLE replay rejection requires firmware/protocol counters, nonces, windows, or equivalent replay protection.
- Secure pairing requires firmware-backed pairing-code authentication, key creation, key rotation, and reset behavior.
- Authenticated node and relay origin identity requires firmware/protocol support, not just SDK/app guards.

### Blocked by Backend/Broker

- Server-side authorization and backend incident authority guarantees remain backend-owned.
- Backend relay validation and topic/session authorization cannot be proven by SDK/app changes alone.
- Broker credential rotation, token refresh/rotation policy, and topic ACL strategy remain backend/broker decisions.

### Blocked by Platform/Infrastructure

- Certificate pinning and custom TLS trust are not implemented.
- TLS trust remains platform/default-library trust unless a later platform review changes it.
- Real secure storage requires adding and validating a platform-backed dependency, then enabling it behind rollout controls.

## Current Risk Register

| Area | Current status | Remaining risk |
| --- | --- | --- |
| SOS lifecycle / authority | Strongly mitigated SDK/App | Future regressions could reintroduce app-side authority if typed SDK authority or the centralized public SOS stream boundary is bypassed. Intentional public transition bypasses remain for constrained authoritative/compatibility paths. |
| SOS transport | Fixed SDK/App | Backend/server-side authorization remains outside the SDK/app scope. |
| Remote relay / LoRa | Strongly mitigated SDK/App for automated gate; manual QA deferred | Remote relay/LoRa cannot be release evidence until manual QA is run. |
| BLE security | Partially mitigated SDK/App | Full fix requires firmware/protocol support for auth, integrity, replay rejection, pairing, and identity. |
| Local storage | Partially mitigated SDK/App | Sensitive state still uses SharedPreferences by default. |
| Secure storage | Partially mitigated SDK/App | Real dependency, enabled flag, migration, and user-data rollout are pending. |
| Diagnostics/PII | Fixed SDK/App | New diagnostics must continue routing through redactors. |
| App architecture | Strongly mitigated SDK/App | `LiveEixamSdkClient` still has future dynamic seam work. |
| Endpoint/network hardening | Strongly mitigated SDK/App | Certificate pinning, broker credential rotation, and backend token policy are not fixed. |

## Next Recommended Actions

1. Complete and record iOS manual QA for login/session restore, BLE discovery/connect, and SOS countdown/cancel.
2. Run remote relay/LoRa manual QA when the required setup is available.
3. Decide whether to add a real platform secure-storage dependency behind the existing disabled flag.
4. Decide the SEC-BLE firmware/protocol roadmap for authenticated links, secure command frames, replay rejection, pairing, and authenticated identity.
5. Decide certificate pinning, custom TLS trust, broker credential rotation, backend token rotation, and topic ACL strategy.
6. Keep app and SDK repos clean before starting new audit patches, especially before touching secure storage, BLE enforcement, or runtime boundary cleanup.

## Non-Claims

- SEC-BLE is not fully fixed.
- Secure storage migration is not complete.
- Backend, broker, infrastructure, native platform, and firmware items are not fixed by this SDK/app checkpoint.
- Public SOS transition bypasses are not fully eliminated; retained bypasses are explicit, constrained, and diagnostic-rich.
- Remote relay/LoRa manual QA has not passed.
- This docs-only checkpoint did not run tests and did not change production behavior.
