# AGENTS.md

This file provides guidance to coding agents (Claude Code, Codex, Cursor, etc.) when working in this repository. It mirrors `CLAUDE.md`.

## Project Context

EIXAM Connect Flutter is the **SDK-first** monorepo for EIXAM's connected safety platform (SOS, device runtime, telemetry, relay ingest, notifications, Death Man Protocol). The SDK is the product; the partner app in `../eixam-app` is a host/reference integration, not the source of truth.

| Path | Role |
| --- | --- |
| `packages/eixam_connect_core` | Public contracts: entities, enums, errors, state machines (`SosStateMachine`, `DeathManStateMachine`), SDK interface |
| `packages/eixam_connect_flutter` | Runtime: BLE, persistence, protection, MQTT, HTTP, permissions, orchestration |
| `packages/eixam_connect_ui` | Reusable UI helpers |
| `docs/ai_context/` | Topic-scoped engineering notes (start at `docs/ai_context/AI_INDEX.md`) |

`core` is a pure Dart package; `flutter` is a Flutter plugin (Android `dev.eixam.connect.flutter` + iOS plugin class). `flutter` depends on `core` via path.

## Commands

Run from the repo root:

```bash
dart format --set-exit-if-changed .         # format check
flutter analyze --no-fatal-infos            # root analysis
flutter test                                # root sweep (may be flaky vs. package-targeted)
```

Package-targeted (more deterministic when narrowing failures):

```bash
dart test packages/eixam_connect_core/test
flutter test packages/eixam_connect_flutter/test
flutter test packages/eixam_connect_flutter/test/sdk/eixam_connect_sdk_impl_test.dart   # single file
```

High-signal tests when changing core flows:

- `packages/eixam_connect_flutter/test/sdk/eixam_connect_sdk_impl_test.dart` — public SDK orchestration
- `packages/eixam_connect_flutter/test/sdk/eixam_connect_sdk_ble_contract_test.dart` — BLE contract surface
- `packages/eixam_connect_flutter/test/ble_auto_reconnect_coordinator_test.dart` — auto reconnect
- `packages/eixam_connect_core/test/state/*`, `packages/eixam_connect_core/test/usecases/*` — SOS/DMP state

Stale-state recovery: `flutter clean && flutter pub get`, and uninstall the app on the device.

## Architecture — Start Here

Trace this path before broad greps:

1. Public bootstrap entry: `EixamConnectSdk.bootstrap(...)` in `packages/eixam_connect_flutter/lib/src/sdk/` — uses `EixamBootstrapResolver` + `ApiSdkFactory` to wire HTTP/MQTT/BLE.
2. Orchestration center: `packages/eixam_connect_flutter/lib/src/sdk/eixam_connect_sdk_impl.dart` composes SOS repo, telemetry repo, device repo, notifications, realtime client, `DeviceSosController`, BLE operational bridge, protection mode adapter.
3. Public state contracts in `core`: `SosState`, `DeviceSosState`, `DeathManStatus`, `RealtimeConnectionState`, `SdkOperationalDiagnostics`, `SosIncident`, `DeviceStatus`.
4. Public SDK interface: `packages/eixam_connect_core/lib/src/interfaces/eixam_connect_sdk.dart`.

### Layer ownership

| Concern | Owner | Key files |
| --- | --- | --- |
| Public contracts, state models | `eixam_connect_core` | `lib/src/state/`, `lib/src/entities/`, `lib/src/interfaces/` |
| SOS orchestration (backend + device) | `eixam_connect_flutter` | `sdk/eixam_connect_sdk_impl.dart`, `sdk/sos_controller.dart` |
| BLE protocol parsing, packet classification, TEL reassembly | `eixam_connect_flutter` | `device/ble_device_runtime_provider.dart`, `device/device_sos_controller.dart` |
| Auto-reconnect, preferred device | `eixam_connect_flutter` | `sdk/ble_auto_reconnect_coordinator.dart` |
| Relay ingest routing + retry policy | `eixam_connect_flutter` | `sdk/ble_operational_runtime_bridge.dart` |
| MQTT realtime + operational publish | `eixam_connect_flutter` | `sdk/mqtt_realtime_client.dart`, `sdk/sdk_mqtt_contract.dart` |
| Backend HTTP transport (signed session) | `eixam_connect_flutter` | `data/datasources_remote/sdk_http_transport.dart`, `data/datasources_remote/http_sos_remote_data_source.dart` |
| DMP monitoring + escalation | `eixam_connect_flutter` | `sdk/eixam_connect_sdk_impl.dart` (DMP wiring) |
| Notifications | `eixam_connect_flutter` | `data/repositories/local_notifications_repository.dart` |
| Android/iOS protection mode | `eixam_connect_flutter` | `sdk/android_protection_platform_adapter.dart`, `sdk/ios_protection_platform_adapter.dart`, `sdk/protection_mode_controller.dart` |

Topic-scoped depth lives in `docs/ai_context/`: `ARCHITECTURE.md`, `SOS_FLOW.md`, `BLE_AND_DEVICE_RUNTIME.md`, `RELAY_FLOW.md`, `DMP_FLOW.md`, `NOTIFICATIONS.md`, `BACKEND_INTEGRATION.md`, `VALIDATION_AND_TESTS.md`. Package-internal contracts: `packages/eixam_connect_flutter/PUBLIC_API.md`, `SOS_ORCHESTRATION.md`, `BLE_DEVICE_CONTRACT.md`.

## Public Bootstrap Contract

```dart
const notificationTexts = EixamNotificationTexts(
  protectionActiveTitle: 'Protection active',
  protectionActiveBody: 'EIXAM is monitoring your connected device.',
  protectionModeTitle: 'Protection mode',
  protectionModeBody: 'Protection mode is running in the background.',
  protectionModeChannelName: 'Protection mode',
  protectionModeChannelDescription: 'Keeps device protection active.',
  protectionSosChannelName: 'SOS alerts',
  protectionSosChannelDescription: 'Shows SOS lifecycle alerts.',
  protectionPreSosTitle: 'SOS countdown',
  protectionPreSosBody: 'An SOS alert is about to be sent.',
  protectionSosActiveTitle: 'SOS active',
  protectionSosActiveBody: 'Your SOS alert is being handled.',
  protectionSosResolvedTitle: 'SOS resolved',
  protectionSosResolvedBody: 'Your SOS alert has been resolved.',
);

final sdk = await EixamConnectSdk.bootstrap(
  const EixamBootstrapConfig(
    appId: 'partner-app',
    environment: EixamEnvironment.production,
    notificationTexts: notificationTexts,
    initialSession: EixamSession.signed(
      appId: 'partner-app',
      externalUserId: 'partner-user-123',
      userHash: 'signed-session-hash',
    ),
  ),
);
```

- `production`, `sandbox`, `staging` resolve internally.
- `EixamEnvironment.custom` requires `EixamCustomEndpoints`; non-custom environments must not receive it.
- `initialSession.appId` must match bootstrap `appId` when provided.
- `notificationTexts` is required and every value must be a non-empty, app-localized string.
- `bootstrap(...)` must not request permissions, pair devices, or trigger UX-sensitive actions.

## Boundary Rules — Do Not Break

- **Keep host apps thin.** Apps render typed SDK state and call public APIs; business-critical behavior does not move into widgets.
- **BLE raw bytes stay SDK-owned.** UI consumes typed `BleIncomingEvent`; widgets never decode byte arrays. Compatibility is validated after connect + service discovery, not by advertised name alone. TEL aggregate reassembly belongs in `BleDeviceRuntimeProvider`.
- **Relay ingest:** when payloads carry a stable remote device identity, telemetry/SOS publish uses that remote backend `deviceId` — the gateway BLE device is diagnostics context only. Relay-origin `422`/unprocessable responses are **terminal** for that publish; the SDK records terminal diagnostics and does not retry. Apps must not add app-side retry for the same relay payload.
- **SOS orchestration** fallback rules (backend, device, or both), DMP timing/escalation, and SOS notification dedup-per-cycle/cleanup are SDK concerns.
- **Realtime:** MQTT is the current production transport, but do not hardcode a final production WebSocket model beyond the current contract — the backend protocol is not finalized.
- **Diagnostics vs. state:** use typed public state for host control flow; use `SdkOperationalDiagnostics` for support-oriented diagnostics.

## Conventions

Lints enabled at root in `analysis_options.yaml` (extends `flutter_lints`):

- `prefer_single_quotes`
- `always_declare_return_types`
- `avoid_print`
- `sort_constructors_first`

When changing runtime behavior, read the relevant tests first and update/add tests with the change. If behavior is unclear, preserve current behavior and mark uncertainty as `Needs verification` rather than guessing.

## Local Development With the Partner App

The partner app at `../eixam-app` keeps an untracked `pubspec_overrides.yaml`:

```yaml
dependency_overrides:
  eixam_connect_core:
    path: ../eixam-sdk-flutter/packages/eixam_connect_core
  eixam_connect_flutter:
    path: ../eixam-sdk-flutter/packages/eixam_connect_flutter
```

CI in the partner app uses the pinned Git ref in its `pubspec.yaml`, so SDK changes ship to the app via merged commits + ref bumps, not transitively.
