# Eixam Connect Flutter documentation

This index is the durable entry point for SDK integrators and maintainers. The
SDK owns SOS lifecycle, capability, transport selection, countdown,
cancellation, recovery, BLE protocol, and persistence semantics. Host apps
consume typed contracts.

## Choose context by task

Read [AGENTS.md](../AGENTS.md) first. This is the canonical index; the retained
`ai_context/` name is historical and its notes are usable by any engineer/agent.

| Task | Minimum documentation and source route |
| --- | --- |
| Change SOS lifecycle | [Lifecycle authority](SOS_LIFECYCLE_ARCHITECTURE_2026.md), [implementation flow/tests](ai_context/SOS_FLOW.md), [validation](ai_context/VALIDATION_AND_TESTS.md); inspect `authoritative_sos_lifecycle_controller.dart` and `sos_lifecycle_matrix_test.dart` in the Flutter package's `lib/src/sdk/` and `test/sdk/` |
| Bootstrap/session/environments | [Integration](SDK_INTEGRATION_GUIDE.md), [public reference](PUBLIC_API_REFERENCE.md), [backend wiring](ai_context/BACKEND_INTEGRATION.md) |
| BLE/pairing/reconnect | [Runtime map](ai_context/BLE_AND_DEVICE_RUNTIME.md), [device contract](../packages/eixam_connect_flutter/BLE_DEVICE_CONTRACT.md), [security](security/ble-security-contract.md) |
| Telemetry/location/relay | [Location ownership](SDK_INTEGRATION_GUIDE.md#location-architecture), [relay](ai_context/RELAY_FLOW.md), [cycle-bound return](LORA_CYCLE_BOUND_RETURN.md) |
| DMP/notifications/background | [DMP](ai_context/DMP_FLOW.md), [notifications](ai_context/NOTIFICATIONS.md), [OS widgets](ai_context/OS_SOS_WIDGETS.md), platform setup in the integration guide |
| Firmware/OTA/provisioning | [Public recovery contract](../packages/eixam_connect_flutter/PUBLIC_API.md#firmware-recovery-contract), [provisioning](device-provisioning/DEVICE_PROVISIONING_ARCHITECTURE.md), [Android factory activation](device-provisioning/ANDROID_FACTORY_ACTIVATION.md), [iOS stock inspection](device-provisioning/IOS_STOCK_INSPECTION.md) |
| Activity recording | [Local engine](ACTIVITY_RECORDING_LOCAL_ENGINE.md), exported optional interfaces and package API notes |

For firmware update implementation inspect
[coordinator](../packages/eixam_connect_flutter/lib/src/sdk/firmware_update_coordinator.dart),
[DFU transport](../packages/eixam_connect_flutter/lib/src/sdk/platform_firmware_dfu_transport.dart)
and [coordinator tests](../packages/eixam_connect_flutter/test/sdk/firmware_update_coordinator_test.dart).
Do not imply a backend/native/device combination is validated merely because an API exists.

## Architecture references

- [SDK integration guide](SDK_INTEGRATION_GUIDE.md)
- [Repository architecture](ai_context/ARCHITECTURE.md)
- [Authoritative SOS lifecycle](SOS_LIFECYCLE_ARCHITECTURE_2026.md)
- [Public API reference](PUBLIC_API_REFERENCE.md)
- [Package-level public API notes](../packages/eixam_connect_flutter/PUBLIC_API.md)
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

- [Host setup, permissions, and location](SDK_INTEGRATION_GUIDE.md#location-architecture)
- [BLE/device runtime](ai_context/BLE_AND_DEVICE_RUNTIME.md)
- [BLE device contract](../packages/eixam_connect_flutter/BLE_DEVICE_CONTRACT.md)
- [OS widget integration](ai_context/OS_SOS_WIDGETS.md)

Application signing, store records, privacy labels/Data Safety, release assets,
and production artifact promotion belong to the host app's release guides.
The SDK package contributes native secure-storage bridges and an iOS privacy
manifest, but does not sign or publish the host application.

## Testing and troubleshooting

- [Integration troubleshooting](SDK_INTEGRATION_GUIDE.md#troubleshooting)
- [Validation commands and historical checkpoints](ai_context/VALIDATION_AND_TESTS.md)
- [Automated SOS validation](sos_lifecycle_validation.md)
- [AI context index](ai_context/AI_INDEX.md)
- [Unreleased summary](RELEASE_NOTES_UNRELEASED.md)

For stale generated/plugin state, run `flutter clean && flutter pub get`, then
uninstall the host app from the test device before repeating restoration tests.

## Historical audits

Documents under `audit/` are retained as historical checkpoint and remediation
evidence. They are not proof that backend, firmware, broker, signing, or store
work was completed.

The [documentation inventory](DOCUMENTATION_INVENTORY_2026.md) records the
purpose, audience, scope, status, and disposition of every documentation
source reviewed for the current release branch.
