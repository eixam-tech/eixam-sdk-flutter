# SDK documentation inventory — 2026-07-27

This inventory was completed before documentation edits on
`release/ios-appstore-preflight` at
`edbfd2328f759ee94908d8d72c201a26cd69670e`. “Historical” means useful evidence
whose point-in-time status must not override the current integration and SOS
guides.

| File | Purpose and audience | Last apparent technical scope | Assessment | Action |
| --- | --- | --- | --- | --- |
| `README.md` | Repository entry for integrators/contributors | SDK-first packages and bootstrap | Current but incomplete for platforms, environment separation, and navigation | Update |
| `CHANGELOG.md` | Version history for integrators | 0.3.0, 2026-07-21 | Missing current branch checkpoint | Update |
| `AGENTS.md` | Engineering guidance for coding agents | 2026-07 SDK architecture | Current; intentionally mirrors `CLAUDE.md` | Retain |
| `CLAUDE.md` | Engineering guidance for compatible agents | Same as `AGENTS.md` | Intentional duplicate | Retain |
| `docs/README.md` | Durable documentation index | Architecture, SOS, security, platform, testing | Current but missing new public guides | Update |
| `docs/SDK_INTEGRATION_GUIDE.md` | Public install, bootstrap, device, location, platform, privacy, troubleshooting guide | Current branch | Missing companion document | Create |
| `docs/PUBLIC_API_REFERENCE.md` | Curated exported-symbol reference | Current public entry point/interface | Missing companion document | Create |
| `docs/DOCUMENTATION_INVENTORY_2026.md` | Audit manifest for reviewers | Current branch | Missing audit record | Create |
| `docs/SOS_LIFECYCLE_ARCHITECTURE_2026.md` | Authoritative lifecycle design for integrators/maintainers | 2026-07 authoritative lifecycle/countdown | Current core; incomplete for new source, progress, identity, and location ownership | Update |
| `docs/sos_lifecycle_validation.md` | Automated/physical lifecycle evidence | 2026-07 current committed heads | Current checkpoint with explicit staging/production boundary | Update |
| `docs/RELEASE_NOTES_UNRELEASED.md` | Unversioned partner release summary | Earlier authoritative lifecycle work | Incomplete for current branch | Update |
| `docs/ai_context/AI_INDEX.md` | Maintainer navigation | 2026-06 topic index | Current internal index | Retain |
| `docs/ai_context/ARCHITECTURE.md` | Internal architecture orientation | 2026-06 subsystem boundaries | Current, intentionally high-level | Retain |
| `docs/ai_context/BACKEND_INTEGRATION.md` | Internal transport/session notes | 2026-06 HTTP/MQTT wiring | Current implementation note; not a final backend protocol promise | Retain |
| `docs/ai_context/BLE_AND_DEVICE_RUNTIME.md` | Internal BLE/reconnect notes | 2026-06 device runtime | Current with an explicit provisioning terminology gap | Retain |
| `docs/ai_context/CODEX_RULES.md` | Legacy agent guardrails | 2026-06 repository scope | Duplicated by current root guidance but harmless/internal | Retain |
| `docs/ai_context/DMP_FLOW.md` | Internal DMP flow | 2026-06 runtime/timers | Current and outside this SOS documentation change | Retain |
| `docs/ai_context/NOTIFICATIONS.md` | Internal notification flow | 2026-06 Android/iOS behavior | Current implementation map | Retain |
| `docs/ai_context/OS_SOS_WIDGETS.md` | Internal OS-widget contract | 2026-07 Android/iOS widgets | Current specialized guide | Retain |
| `docs/ai_context/RELAY_FLOW.md` | Internal own-device/relay classification | 2026-06 relay routing/422 | Current; public history-only rule is now also in authoritative guides | Retain |
| `docs/ai_context/SOS_FLOW.md` | Internal SOS call paths | 2026-07 app/device flows | Current deep implementation map | Retain |
| `docs/ai_context/VALIDATION_AND_TESTS.md` | Maintainer commands and matrices | 2026-07 current committed heads | Current commands and checkpoint | Update |
| `docs/audit/local-storage-security-inventory.md` | Security evidence | 2026-07 SDK/app local storage | Historical point-in-time inventory | Retain |
| `docs/audit/network-security-hardening-inventory.md` | Security evidence | 2026-07 transport posture | Historical with unresolved items | Retain |
| `docs/audit/sdk-app-audit-global-checkpoint.md` | Cross-repository audit checkpoint | 2026-07 remediation status | Historical; backend/firmware statements are scoped findings, not current release requirements | Retain |
| `docs/audit/sdk-app-audit-guardrails-checklist.md` | Engineering regression guardrails | 2026-06 safety checklist | Current internal checklist | Retain |
| `docs/audit/sdk-app-remediation-tracker.md` | Finding-by-finding evidence | 2026-07 remediation status | Historical; some future protocol work remains intentionally unresolved | Retain |
| `docs/audit/secure-storage-abstraction-plan.md` | Storage migration design/evidence | 2026-07 | Historical design plus completed mitigation context | Retain |
| `docs/security/ble-security-contract.md` | BLE threat model and phased security contract | 2026-06 | Current design document; future firmware items are not app-release prerequisites | Retain |
| `packages/eixam_connect_flutter/PUBLIC_API.md` | Package-local integration notes | 2026-07 lifecycle/capability/relay | Current but narrower than a full public reference | Retain; add companion |
| `packages/eixam_connect_flutter/SOS_ORCHESTRATION.md` | Package-local SOS behavior contract | 2026-07 transport/capability | Current deep guide | Retain |
| `packages/eixam_connect_flutter/BLE_DEVICE_CONTRACT.md` | Package-local BLE/command/relay contract | 2026-06/07 | Current specialized guide | Retain |

`docs/.DS_Store` and `docs/audit/.DS_Store` are tracked filesystem metadata,
not documentation. They were not modified. Package `pubspec.yaml` files and the
iOS podspec were inspected for documentation links, platform declarations,
package versions, and supported SDK ranges; none references an additional
Markdown source.

No document was merged, archived, removed, or replaced. New companion guides
were created because the existing internal architecture and package notes
could not cleanly serve as a public installation/platform/troubleshooting
guide or a curated exported API index.
