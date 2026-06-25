# SDK/App Audit Guardrails Checklist

Use this checklist before SDK/app audit-sensitive PRs or patches. It is a review aid, not approval to change backend, firmware, native project files, generated files, production runtime code outside the intended scope, or `build/test_cache`.

## SOS Lifecycle

- App code renders SDK SOS state; it must not fabricate synthetic SOS sending or active states.
- Backend/history SOS records must not become local active SOS without typed SDK authority.
- Public SDK SOS state writes remain centralized through the guarded public SOS boundary.
- Any new public SOS state-machine bypass has an explicit allow-list entry, reason, authority, origin, policy, and focused tests.
- External or remote relay SOS remains external/history/non-local-actionable and must not become local active SOS.

## Transport

- SOS trigger remains MQTT-only.
- HTTP SOS trigger remains blocked.
- HTTP cancel and read-only behavior remain preserved.
- MQTT lifecycle updates remain authority-gated by topic/session/lifecycle authority checks.

## Storage And Auth

- Secure storage flags remain disabled by default unless explicitly approved for rollout.
- Real token/session migration requires a feature flag, rollback path, focused tests, and manual QA.
- Corrupt secure-storage data must not unexpectedly delete a valid legacy session.
- Logout/session cleanup clears intended secure and legacy paths best-effort.
- Telemetry, diagnostics, and debug stores must not persist raw Bearer, Authorization, or token strings.

## Diagnostics And PII

- New diagnostics and logs pass through redaction helpers.
- Do not log raw BLE hex, coordinates, identities, headers, MQTT topics, tokens, or payload bodies outside an explicit debug-only path.

## BLE

- SEC-BLE strict mode must not be enabled for legacy devices.
- Any new critical BLE command is classified.
- Critical BLE commands have focused tests.
- SDK Phase 0 scaffolding is partial mitigation only; it is not full BLE security.

## App/SDK Boundary

- Prefer typed SDK APIs at the app boundary.
- Do not add broad dynamic SOS authority fallbacks.
- Missing SOS authority metadata remains conservative: external/history/non-local-actionable.
- Any dynamic fallback is centralized, named as legacy compatibility, and covered by tests where behavior matters.

## Repo Hygiene

- Do not commit `build/test_cache`.
- Do not commit generated files.
- Do not mix docs, app runtime, SDK runtime, native, backend, or firmware changes in one audit commit.
- App and SDK repos should be clean before starting a new patch.
- Keep one finding per commit where possible.

## QA

- SOS lifecycle changes: run state-machine, lifecycle matrix, and remote relay tests.
- Auth/storage changes: run auth, session, and smoke tests.
- BLE/devices changes: run reconnect, devices, and readiness tests.
- Diagnostics changes: run redaction tests.
- Record Android manual QA after meaningful app/device changes.
- iOS manual QA remains final acceptance.
