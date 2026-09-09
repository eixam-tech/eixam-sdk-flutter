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
- Lab unprovision is SDK-owned (`unprovisionDevice()` → `0x25` then `0x22`). Hosts never write the opcode. Firmware ≥ 2.7.53. Always reboot after OK / OK_NOCHANGE so the Eixam stack drops, even if `0x23` already reads unprovisioned. Skip reboot on REJECT. Advertising keeps the Eixam UUID so the app can reconnect. CMD is write-with-response: a dropped ATT ACK after `0x22` is still success if the reboot disconnect is in window (900 ms–12 s from write start, raw GATT status — not the protection-bridged public `connected` flag). Android often reports the drop as `LINK_SUPERVISION_TIMEOUT` after the 1.5 s scheduled reboot. Post-reconnect `0x23` is retried for both unprovision and SoftSIM+SOS RF apply — GATT/notify is often not ready on the first attempt after reboot.
- `E_DEVICE_COMMAND_NOT_READY` is the expected failure when command routing is unavailable.

## Notification / Subscription Behavior

- BLE runtime subscribes to EIXAM notifications after connect/service discovery.
- Packet handling includes:
  - TEL fragments and aggregate completion
  - runtime status packets
  - relay packets
  - SOS packets and 6-byte SOS control events (`0xE1`/`0xE2`/`0xE3`)
  - cluster heartbeat packets
- Firmware ≥ 2.7.54 mirrors those 6-byte events on TEL as well as SOS, because
  a stale Android GATT cache can leave SOS CCCD unsubscribed while TEL still
  delivers the countdown and active SOS. Duplicate SOS+TEL copies share
  `rawHex` and are suppressed. `0xE1` is the user/tag cancel; `0xE3` is
  backend `ACK_SOS`, not a user cancel. A connected-TAG `0xE1`/`0x02` is
  applied locally even when BLE node identity is still unknown — otherwise
  the physical 3 s hold never closes the host SOS. HTTP cancel of a
  provisional `sos-*` id must not block that local close.
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
  - native Protection Mode is **not** a live BLE owner (background, or leftover native GATT)
- `AppLifecycleState.inactive` and `hidden` are not treated as background.
  Cold-start splash/surface recreation and BLE bond/permission dialogs fire
  those states while the user is still looking at the app. Mapping them to
  background aborts the preferred-reconnect campaign as `app_not_foreground`
  (not retryable) after the first GATT failure. Only `paused` and `detached`
  drop the foreground flag.
- Unexpected disconnect triggers retry backoff.
-   After GATT is up, pair/reconnect hydrate `0x23` runtime status, firmware, and
  RSSI in parallel. Notify must be bound first so the status reply can arrive.
  Overlapping `0x23` callers join the in-flight reply instead of throwing
  `E_DEVICE_STATUS_TIMEOUT`. Country-config checks stay queued while
  `ensureDeviceReady` / `unprovisionDevice` own the reboot boundary.
  `flutter_blue_plus` still serializes GATT ops; the win is overlapping the
  `0x23` notify wait with DIS/RSSI reads.
- Connect skips FBP's default Android MTU 512 exchange (`mtu: null`) and, on
  Android, requests `ConnectionPriority.high`. The 350 ms post-connect
  stabilization delay is unchanged. Service discovery does not subscribe to
  Services Changed (`onServicesReset` is unused). Android still caches GATT
  handles by MAC: provision hides Meshtastic Phone BLE and unprovision puts
  it back, so SOS CCCD writes hit a stale read-only handle
  (`GATT_WRITE_NOT_PERMITTED`) unless `clearGattCache()` / hidden
  `BluetoothGatt.refresh()` runs before `discoverServices()`. Flutter and
  native Protection Mode both clear the cache on every Android connect. A
  SOS CCCD `WRITE_NOT_PERMITTED` also triggers one in-session refresh+retry.
- Flutter reconnect skips the campaign while native Protection Mode owns BLE
  **and** either the app is backgrounded **or** native already has a live GATT.
  A leftover foreground service that is actually connected must not be torn
  down just because the app is on screen; public device status bridges that
  native link. Yield / force-reconnect native only after a real background
  handoff (`flutter_yielded`). `setAppForeground(false)` follows real
  `paused`/`detached`, not leftover native-live status.
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
- `packages/eixam_connect_flutter/test/device/ble_device_runtime_provider_payload_classification_test.dart`
- `packages/eixam_connect_flutter/test/device/android_ble_gatt_cache_test.dart`
- `packages/eixam_connect_flutter/test/device/eixam_ble_command_test.dart`
- `packages/eixam_connect_flutter/test/device/eixam_sos_packet_test.dart`
- `packages/eixam_connect_flutter/test/device/eixam_sos_event_packet_test.dart`

## Needs Verification

- The repo clearly defines reconnect mechanics, but there is not yet a single canonical document defining every human-facing meaning of `pair` vs `activate` across real hardware provisioning flows. Preserve current code behavior and validation flows.
