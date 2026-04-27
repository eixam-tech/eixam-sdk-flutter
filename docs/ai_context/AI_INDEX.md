# AI Context Index

This folder is a lightweight orientation layer for future Codex sessions working in the EIXAM repository.

## What EIXAM Is

- EIXAM is a connected safety platform with SOS, device runtime, telemetry, relay ingest, notifications, and Death Man Protocol support.
- This repo is **SDK-first**:
  - `packages/eixam_connect_core` holds public contracts, entities, enums, and domain state models.
  - `packages/eixam_connect_flutter` holds runtime implementation: BLE, persistence, notifications, MQTT, HTTP, permissions, and orchestration.
  - `apps/eixam_control_app` is a thin validation host, not the partner product UX.

## Read First By Task

| Task | Read first |
|---|---|
| General repo orientation | [`../../README.md`](../../README.md), [`../../AGENTS.md`](../../AGENTS.md), [`ARCHITECTURE.md`](ARCHITECTURE.md) |
| Public SDK / bootstrap / session questions | [`ARCHITECTURE.md`](ARCHITECTURE.md), [`BACKEND_INTEGRATION.md`](BACKEND_INTEGRATION.md), [`../../packages/eixam_connect_flutter/lib/src/sdk/api_sdk_factory.dart`](../../packages/eixam_connect_flutter/lib/src/sdk/api_sdk_factory.dart) |
| SOS behavior | [`SOS_FLOW.md`](SOS_FLOW.md), [`../../packages/eixam_connect_flutter/SOS_ORCHESTRATION.md`](../../packages/eixam_connect_flutter/SOS_ORCHESTRATION.md), [`../../packages/eixam_connect_flutter/lib/src/sdk/eixam_connect_sdk_impl.dart`](../../packages/eixam_connect_flutter/lib/src/sdk/eixam_connect_sdk_impl.dart) |
| BLE / device runtime | [`BLE_AND_DEVICE_RUNTIME.md`](BLE_AND_DEVICE_RUNTIME.md), [`../../packages/eixam_connect_flutter/BLE_DEVICE_CONTRACT.md`](../../packages/eixam_connect_flutter/BLE_DEVICE_CONTRACT.md), [`../../packages/eixam_connect_flutter/lib/src/device/ble_device_runtime_provider.dart`](../../packages/eixam_connect_flutter/lib/src/device/ble_device_runtime_provider.dart) |
| Relay / remote-node behavior | [`RELAY_FLOW.md`](RELAY_FLOW.md), [`../../packages/eixam_connect_flutter/lib/src/sdk/ble_operational_runtime_bridge.dart`](../../packages/eixam_connect_flutter/lib/src/sdk/ble_operational_runtime_bridge.dart) |
| DMP / Death Man | [`DMP_FLOW.md`](DMP_FLOW.md), [`../../packages/eixam_connect_flutter/lib/src/sdk/eixam_connect_sdk_impl.dart`](../../packages/eixam_connect_flutter/lib/src/sdk/eixam_connect_sdk_impl.dart) |
| Notifications | [`NOTIFICATIONS.md`](NOTIFICATIONS.md), [`../../packages/eixam_connect_flutter/lib/src/data/repositories/local_notifications_repository.dart`](../../packages/eixam_connect_flutter/lib/src/data/repositories/local_notifications_repository.dart) |
| Validation app surface | [`ARCHITECTURE.md`](ARCHITECTURE.md), [`../../apps/eixam_control_app/lib/src/app_shell/app_shell_screen.dart`](../../apps/eixam_control_app/lib/src/app_shell/app_shell_screen.dart), [`../../apps/eixam_control_app/lib/src/features/operational_demo/validation_console_controller.dart`](../../apps/eixam_control_app/lib/src/features/operational_demo/validation_console_controller.dart) |
| How to validate changes | [`VALIDATION_AND_TESTS.md`](VALIDATION_AND_TESTS.md) |
| Session rules for Codex | [`CODEX_RULES.md`](CODEX_RULES.md) |

## AI Context Files

- [`ARCHITECTURE.md`](ARCHITECTURE.md)
- [`SOS_FLOW.md`](SOS_FLOW.md)
- [`BLE_AND_DEVICE_RUNTIME.md`](BLE_AND_DEVICE_RUNTIME.md)
- [`RELAY_FLOW.md`](RELAY_FLOW.md)
- [`DMP_FLOW.md`](DMP_FLOW.md)
- [`NOTIFICATIONS.md`](NOTIFICATIONS.md)
- [`BACKEND_INTEGRATION.md`](BACKEND_INTEGRATION.md)
- [`VALIDATION_AND_TESTS.md`](VALIDATION_AND_TESTS.md)
- [`CODEX_RULES.md`](CODEX_RULES.md)

## Before Touching Code

- Read `AGENTS.md` and preserve the SDK-first architecture.
- Check whether the logic belongs in `eixam_connect_core`, `eixam_connect_flutter`, or only in the validation app.
- Prefer existing SDK public facades before adding new app-side orchestration.
- Find the current tests covering the area before editing.
- If behavior is unclear, mark it as `Needs verification` instead of guessing.

## Do Not Break

- Public bootstrap contract and session/appId rules.
- SOS orchestration fallback rules: backend, device, or both.
- BLE packet parsing ownership inside runtime layers, not widgets.
- Relay ingest routing and terminal `422` handling.
- Death Man timing/escalation flow.
- The control app remaining a thin SDK host.
