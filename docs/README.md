# Eixam Connect Flutter documentation

This index is the durable entry point for SDK integrators and maintainers. The
SDK owns SOS lifecycle, capability, transport selection, countdown,
cancellation, recovery, BLE protocol, and persistence semantics. Host apps
consume typed contracts.

## Architecture

- [Repository architecture](ai_context/ARCHITECTURE.md)
- [Authoritative SOS lifecycle](SOS_LIFECYCLE_ARCHITECTURE_2026.md)
- [Public API notes](../packages/eixam_connect_flutter/PUBLIC_API.md)
- [Backend integration](ai_context/BACKEND_INTEGRATION.md)

## SOS

- [Authoritative SOS lifecycle](SOS_LIFECYCLE_ARCHITECTURE_2026.md)
- [SOS orchestration](../packages/eixam_connect_flutter/SOS_ORCHESTRATION.md)
- [SOS flow](ai_context/SOS_FLOW.md)
- [Automated lifecycle validation](sos_lifecycle_validation.md)
- [OS widgets](ai_context/OS_SOS_WIDGETS.md)

## Privacy, compliance, and security

- [Local-storage security inventory](audit/local-storage-security-inventory.md)
- [Network-security inventory](audit/network-security-hardening-inventory.md)
- [BLE security contract](security/ble-security-contract.md)

The SOS provenance store is account-scoped and platform-secure, and excludes
coordinates, contacts, payloads, raw packets, credentials, and location
history. Historical security/audit notes may describe earlier checkpoints;
their explicit unresolved risks remain important, but the current SOS
architecture document takes precedence for lifecycle persistence.

## Android and iOS integration

- [BLE/device runtime](ai_context/BLE_AND_DEVICE_RUNTIME.md)
- [BLE device contract](../packages/eixam_connect_flutter/BLE_DEVICE_CONTRACT.md)
- [OS widget integration](ai_context/OS_SOS_WIDGETS.md)

Application signing, store records, privacy labels/Data Safety, release assets,
and production artifact promotion belong to the host app's release guides.
The SDK package contributes native secure-storage bridges and an iOS privacy
manifest, but does not sign or publish the host application.

## Testing and troubleshooting

- [Validation commands and final status](ai_context/VALIDATION_AND_TESTS.md)
- [Automated SOS validation](sos_lifecycle_validation.md)
- [AI context index](ai_context/AI_INDEX.md)
- [Unreleased summary](RELEASE_NOTES_UNRELEASED.md)

For stale generated/plugin state, run `flutter clean && flutter pub get`, then
uninstall the host app from the test device before repeating restoration tests.

## Historical audits

Documents under `audit/` are retained as historical checkpoint and remediation
evidence. They are not proof that backend, firmware, broker, signing, or store
work was completed.
