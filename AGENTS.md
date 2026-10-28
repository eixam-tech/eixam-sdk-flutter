# EIXAM Connect SDK — engineering entry point

Canonical shared instructions for all coding agents. Select a focused task route
in [docs/README.md](docs/README.md), then read the relevant source and tests.

## Role and ownership

The SDK is the reusable product. Determine ownership before implementing features:

| Repository/layer | Owns |
| --- | --- |
| `eixam_connect_core` | Pure Dart public contracts, entities, enums, errors and domain state machines |
| `eixam_connect_flutter` | SOS orchestration, BLE/protocol, device runtime/reconnect, telemetry/location/relay, DMP, notifications, native background and firmware updates |
| `eixam_connect_ui` | Reusable Flutter UI helpers |
| Commercial `eixam-app` | Product presentation, navigation, localization, composition and product integrations |
| `eixam-sdk-demo-flutter` | Reference integration, vertical demonstrations and controlled device validation |

Implement and verify shared behavior in the SDK before host integration.
Hosts consume typed state and public APIs. No private SDK `src/` imports,
BLE decoding in widgets, duplicate lifecycle, transport retries or device logic.
When firmware/SDK contracts change, update both hosts in the same task where
affected; review both even if one needs no edit. Preserve observable semantics.
An SDK checkout change does not update consumers' immutable Git pins.

## Source entry points

- [Public Flutter exports](packages/eixam_connect_flutter/lib/eixam_connect_flutter.dart)
  define the consumer boundary, including optional capabilities.
- [Core interface](packages/eixam_connect_core/lib/src/interfaces/eixam_connect_sdk.dart).
- [Bootstrap factory](packages/eixam_connect_flutter/lib/src/sdk/api_sdk_factory.dart)
  and [resolver](packages/eixam_connect_flutter/lib/src/sdk/eixam_bootstrap_resolver.dart).
- [Runtime composition](packages/eixam_connect_flutter/lib/src/sdk/eixam_connect_sdk_impl.dart).
- [SOS lifecycle authority](docs/SOS_LIFECYCLE_ARCHITECTURE_2026.md) and
  [implementation flow](docs/ai_context/SOS_FLOW.md).
- [BLE runtime](docs/ai_context/BLE_AND_DEVICE_RUNTIME.md),
  [relay](docs/ai_context/RELAY_FLOW.md), [DMP](docs/ai_context/DMP_FLOW.md),
  [notifications](docs/ai_context/NOTIFICATIONS.md) provide focused source/test maps.
- [Integration guide](docs/SDK_INTEGRATION_GUIDE.md) owns bootstrap, sessions,
  environments, Android/iOS setup, permissions, location and troubleshooting.
- [Public API notes](packages/eixam_connect_flutter/PUBLIC_API.md) include
  firmware recovery, provisioning, Activity and position batch contracts.

## Critical invariants

- SOS is safety-critical. Analyze activation, cancellation, resolution, failure,
  recovery, process death and regression effects before changing behavior.
- Bootstrap takes localized nonempty notification texts. Initial signed session
  app ID must match bootstrap. Hosts obtain signing from a trusted service;
  bootstrap must not prompt permissions, pair devices or trigger UX actions.
  Non-custom environments resolve internally; `custom` requires explicit
  `EixamCustomEndpoints`, which must not be supplied to other environments.
- BLE compatibility requires connection/service discovery, not a device name.
  TEL reassembly and packet classification stay in SDK runtime layers.
- 7-byte `sosType = 3` keeps SOS open; last-known fixes keep timestamp/age;
  never paint `0°,0°`. SOS GATT 12-byte frames remain SOS with bit 5 set;
  TEL classification has its own gate. `ACK_SOS` / `0xE3` is not user cancel.
- Relay ingest with stable remote identity publishes for the remote device,
  not the gateway. Relay-origin `422`/unprocessable is terminal for that publish;
  hosts must not add retries.
- SOS fallback, DMP timing/escalation and notification deduplication/cleanup
  belong in the SDK. Typed public state drives control flow; operational
  diagnostics support troubleshooting, not lifecycle authority.
- MQTT is current operational realtime wiring. Do not invent a finalized
  production WebSocket contract.
- Preserve secure account-scoped persistence and privacy boundaries. Never
  document credentials, signed sessions, sensitive payloads or user data.
  Never promise guaranteed connectivity, alert delivery or rescue.

## Validation and compatibility

Use Dart/Flutter constraints from manifests rather than old guide prose.
From the root, after resolving the relevant package dependencies:

```sh
dart format --output=none --set-exit-if-changed .
flutter analyze --no-fatal-infos
(cd packages/eixam_connect_core && dart test)
(cd packages/eixam_connect_flutter && flutter test)
```

Use [validation](docs/ai_context/VALIDATION_AND_TESTS.md) for focused tests and
physical scenarios. Root `flutter test` alone does not cover both packages.
For public API changes inspect exports, implementations, mocks and both hosts'
pins/overrides; retain compatibility or explicitly document migration.
Local host iteration uses ignored path overrides, resolved through
`.dart_tool/package_config.json`; CI/release uses reviewed immutable Git pins.
Paths depend on checkout layout; follow each host's setup.
Preserve overrides/backups. Baseline/release checks must have no active local QA
override. Local validation is not release proof.
Lints are defined in [analysis_options.yaml](analysis_options.yaml):
single quotes, declared return types, no print and constructors first.

## Proportionate engineering workflow

1. Read applicable instructions and the task route; inspect related code/tests.
2. Identify ownership, SDK-first implications and downstream consumers.
3. Define acceptance for nontrivial changes, including failure/recovery.
4. Make the smallest coherent change using existing patterns.
5. Run relevant validation; review compatibility, regressions, privacy and UX.
6. Report files/behavior changed, actual checks/results, skips and residual risks.

For behavior changes update/add relevant regression coverage. If behavior is
unclear, preserve it and record `Needs verification` rather than guessing.

Trivial edits need no architectural ceremony. External AI skills/tools are optional.
Separate implemented behavior/current decisions from plans and assumptions.
Keep historical evidence with revision/environment; it is not current proof.
Automated tests never replace physical Android/iOS TAG/background validation.
Distinguish simulation, STAGING and production; preserve release/review gates.
Do not push, merge, publish or alter unrelated work without authorization.
