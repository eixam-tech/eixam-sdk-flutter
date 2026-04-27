# BLE And Device Runtime

## Main Sources

- Runtime provider: `packages/eixam_connect_flutter/lib/src/device/ble_device_runtime_provider.dart`
- Device SOS state handling: `packages/eixam_connect_flutter/lib/src/device/device_sos_controller.dart`
- Repository wrapper: `packages/eixam_connect_flutter/lib/src/data/repositories/in_memory_device_repository.dart`
- Auto-reconnect: `packages/eixam_connect_flutter/lib/src/sdk/ble_auto_reconnect_coordinator.dart`
- Public notes: `packages/eixam_connect_flutter/BLE_DEVICE_CONTRACT.md`

## Pairing / Binding Concepts

- The repo uses `pairDevice(...)` and `activateDevice(...)` as separate steps.
- `DeviceStatus` tracks:
  - `paired`
  - `activated`
  - `connected`
  - lifecycle state
- Preferred reconnect target is stored in `PreferredBleDeviceStore`.
- Manual disconnect state is also persisted so auto-reconnect can stay disabled until the next manual connect.

## Runtime Connection States

- BLE debug connection states include connecting, connected, reconnect scheduled, manual disconnect, unexpected disconnect, failed, and incompatible.
- Effective public device status comes from `DeviceStatus`.
- `BleDeviceRuntimeProvider` also tracks ownership transfer when protection mode takes BLE away from Flutter.

## Command Readiness

- SOS availability depends on a live SOS write path.
- Device commands such as notification volume, SOS volume, reboot, and runtime status require a compatible connected command-capable device.
- `E_DEVICE_COMMAND_NOT_READY` is the expected failure when command routing is unavailable.

## Notification / Subscription Behavior

- BLE runtime subscribes to EIXAM notifications after connect/service discovery.
- Packet handling includes:
  - TEL fragments and aggregate completion
  - runtime status packets
  - guided rescue status packets
  - relay packets
  - SOS packets
  - cluster heartbeat packets
  - backlog sync frames
- Host apps should never decode these payloads directly.

## Device-Origin Events

- Device-origin SOS status is derived in `DeviceSosController`.
- Trigger origin and transition source are tracked separately.
- Relay count and remote identity can change how the SDK treats a packet:
  - local device-origin event
  - relayed remote-node event
  - app-correlated event

## Reconnect / Resume Edge Cases

- Auto-reconnect only runs when:
  - manual disconnect is not active
  - app is foregrounded, except startup path
  - no connection attempt is already in progress
  - a preferred device is stored
- Unexpected disconnect triggers retry backoff.
- Backlog sync restart on reconnect is SDK-owned.
- When protection mode owns BLE, Flutter releases ownership and later reclaims it.
- `BleDeviceRuntimeProvider` can suspend and resume ownership for this handoff.

## Main Files

- `packages/eixam_connect_flutter/lib/src/device/ble_device_runtime_provider.dart`
- `packages/eixam_connect_flutter/lib/src/device/device_sos_controller.dart`
- `packages/eixam_connect_flutter/lib/src/data/repositories/in_memory_device_repository.dart`
- `packages/eixam_connect_flutter/lib/src/sdk/ble_auto_reconnect_coordinator.dart`
- `packages/eixam_connect_flutter/lib/src/data/datasources_local/preferred_ble_device_store.dart`
- `packages/eixam_connect_core/lib/src/entities/device_status.dart`
- `packages/eixam_connect_core/lib/src/entities/device_runtime_status.dart`

## Related Tests

- `packages/eixam_connect_flutter/test/ble_auto_reconnect_coordinator_test.dart`
- `packages/eixam_connect_flutter/test/data/repositories/in_memory_device_repository_test.dart`
- `packages/eixam_connect_flutter/test/device/ble_device_runtime_provider_device_control_test.dart`
- `packages/eixam_connect_flutter/test/device/ble_device_runtime_provider_guided_rescue_test.dart`
- `packages/eixam_connect_flutter/test/device/ble_device_runtime_provider_payload_classification_test.dart`
- `packages/eixam_connect_flutter/test/device/eixam_ble_command_test.dart`
- `packages/eixam_connect_flutter/test/device/eixam_backlog_sync_frame_test.dart`
- `packages/eixam_connect_flutter/test/device/eixam_sos_packet_test.dart`
- `packages/eixam_connect_flutter/test/device/eixam_sos_event_packet_test.dart`

## Needs Verification

- The repo clearly defines reconnect mechanics, but there is not yet a single canonical document defining every human-facing meaning of `pair` vs `activate` across real hardware provisioning flows. Preserve current code behavior and validation flows.
