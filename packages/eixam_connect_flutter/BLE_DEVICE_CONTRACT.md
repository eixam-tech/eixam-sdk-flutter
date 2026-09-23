# BLE Device Contract

## Why This Exists

The Flutter SDK is responsible for hiding the EIXAM BLE protocol from host apps. Host apps should call typed SDK APIs for SOS, device control, runtime inspection, and typed relay telemetry instead of sending raw BLE commands or decoding packets themselves.

For relay ingest specifically:

- host apps consume typed SDK state and diagnostics
- the SDK owns backend routing and terminal handling
- host apps must not implement their own relay protocol state machines

## Public SOS Diagnostics And Availability

Host apps can read SOS channel readiness and the most recent public delivery path from `SdkOperationalDiagnostics`:

- `backendSosAvailable`
- `deviceSosAvailable`
- `canActivateSos`
- `currentSosCapabilityChannel`
- `currentSosCapabilityLabel`
- `lastPublicSosDeliveryChannel`

The actual incident channel is also exposed on `SosIncident.deliveryChannel`.

Possible delivery values:

- `backendOnly`
- `deviceOnly`
- `backendAndDevice`

This keeps SOS routing explicit for host UX, incident history, and support diagnostics.

Capability and delivery are intentionally separate:

- capability answers what the SDK can use right now
- delivery answers what the SDK actually used for the active or last public SOS request

For SOS specifically, `deviceSosAvailable` means the SDK currently has a real
device command path for SOS writes. It is not the same as generic device
readiness such as `DeviceStatus.isReadyForSafety`.

## Public Device Control APIs

The SDK now exposes the following typed BLE-backed controls:

- `setDeviceNotificationVolume(int volume)`
- `setDeviceSosVolume(int volume)`
- `rebootDevice()`
- `getDeviceRuntimeStatus()`

### Volume Commands

- `setDeviceNotificationVolume` maps to protocol command `0x11 BUZZER_NOTIFY_VOL`
- `setDeviceSosVolume` maps to protocol command `0x12 BUZZER_SOS_VOL`
- accepted range is `0..100`
- `0` is valid and can be used as mute
- calls fail with `E_DEVICE_COMMAND_NOT_READY` when no connected command-capable device exists
- invalid values fail with `E_DEVICE_INVALID_VOLUME`

## Device SOS Command Path

The SDK treats the device SOS path as available only when all of the following
are true:

- the device is currently connected
- the device is EIXAM-compatible
- the runtime has a live SOS command write path

That SOS write path is defined by the actual BLE command route used for SOS
commands:

- `0x06 SOS_TRIGGER_APP`
- `0x04 SOS_CANCEL`
- `0x05 SOS_CONFIRM`

These commands use the normal EIXAM write path selected by the SDK runtime.
Because they are single-byte commands, they may be writable through INET and do
not require CMD when INET is sufficient.

This means host apps should trust `SdkOperationalDiagnostics.deviceSosAvailable`
and `currentSosCapabilityChannel` as the current SOS capability truth exposed by
the SDK.

### Reboot

- `rebootDevice()` maps to protocol command `0x22 REBOOT`
- the SDK only attempts it when a connected command-capable device exists
- provisioning treats the reboot drop from raw GATT status (900 ms–12 s), not
  the protection-bridged public `connected` flag. Android often reports
  `LINK_SUPERVISION_TIMEOUT` after the firmware 1.5 s reboot schedule.

### Runtime Status

- `getDeviceRuntimeStatus()` sends `0x23 GET_DEVICE_STATUS`
- the SDK parses the `E9 78 01` 12-byte TEL response into `DeviceRuntimeStatus`
- host apps receive typed fields instead of raw bytes:
  - `region`
  - `modemPreset`
  - `meshSpreadingFactor`
  - `isProvisioned`
  - `usePreset`
  - `txEnabled`
  - `inetOk`
  - `positionConfirmed`
  - `nodeId`
  - `batteryPercent`
  - `telIntervalSeconds`

Failure semantics:

- no command-capable device: `E_DEVICE_COMMAND_NOT_READY`
- no valid response before timeout: `E_DEVICE_STATUS_TIMEOUT`
- a second `0x23` while one is in flight joins that reply instead of failing immediately
- malformed or unsupported payloads are ignored safely until timeout

## Nearby LoRa text (port 262)

Host apps call `sendNearbyBroadcastText` / `sendNearbyDirectText` /
`sendNearbyGroupText` / `watchNearbyText` / `watchNearbyTextTxStatus`. They never decode BLE or LoRa bytes.

- mesh port **262** (`EIXAM_TEXT_APP`), hop **0**. PKI DMs set `want_ack = true`. Plaza/group stay `want_ack = false` on air; hop-0 receivers send a staggered ROUTING ACK and cancel if they overhear one (firmware ≥ **2.7.63**)
- plaza: `dest=broadcast`, PRIMARY PSK, UTF-8 1–**231** B on TX (`nearbyTextPayloadMaxBytes`). The firmware router adds `has_bitfield` to its own packets, so the mesh `Data` protobuf costs 8 B on top of the text and 232–233 B would be `TOO_LARGE`. RX still accepts up to 233 B (`nearbyTextRxPayloadMaxBytes`)
- DM: `dest=nodeId`, PKI (`pki_encrypted`), 1–200 B. No channel-PSK fallback
- group: `groupId≠0` on a SECONDARY PSK from `setNearbyGroup` (`0x41`), same 231 B cap
- phone TX: CMD `0x40` fragments (maxLen 20, chunk ≤15). Blob = `dest u32` + `packetId u32` + `groupId u64` + utf8
- phone RX: TEL notify `0xD8` (22 B header + utf8); blobs reuse `0xD0` reassembly
- a `0xD8` blob is 22 B header + ≥1 B text, so it never has an SOS/TEL notify size (6/7/10/12/13/16/18). Firmware ≤ 2.7.56 padded with trailing `0xFF`; the SDK still strips those bytes before UTF-8 decode
- TX status: 6 B `0xDA` (on_air / SOS / rate / PSA / utf8 / too_long / not_prov / empty / bad_frame / pkiNoKey / pkiFailed / unknownGroup / **meshAck / recipientAck / ackTimeout / gotNak**). Delivery statuses `12`–`15` are follow-ups after on-air
- firmware ≥ **2.7.56** for the framing (2.7.55 plaza-only framing is not compatible); ≥ **2.7.57** for the 231 B cap and the fleet-channel gate (TEL/SOS/cluster ignore SECONDARY group keys); ≥ **2.7.58** for `0x42` / `0xDB`; ≥ **2.7.59** for 7 slots + SET_REPLACE; ≥ **2.7.63** for delivery ACK `0xDA` 12–15
- `0xD4` / `0xD5` stay reserved dense TEL twins
- no MQTT/HTTP fallback; `timeout` means the TAG never answered `0xDA`
- Native protection owns GATT in background but is the BLE pipe, not a Nearby lock. It writes CMD `0x40`/`0x41`/`0x42` and forwards non-SOS TEL notifies (`0xD0`/`0xDA`/`0xD8`/`0xDB`/`E9 7A`) to Dart as `telNotifyReceived`. If Dart is detached, native queues those payloads and flushes them on the next event-channel listen. `NearbyTextTxStatus.bleOwnedByProtection` is unused on current SDKs
- TX is refused during pre-SOS/SOS; incoming is still delivered if BLE handed it over
- `0xDA` is 6 bytes like SOS events `0xE1`/`0xE2`/`0xE3`. Classify by opcode, never by length. Firmware drain: SOS notify, then TEL small, then a burst of up to 8 `0xD0` fragments per 100 ms tick (≥ 2.7.57)
- `setNearbyGroup` REJECT `detail=0xFF` means all 7 SECONDARY slots are full (`slotsFull`). Pass `replace: true` (CMD action 2) to wipe tag groups and install this one. `0xFE` is a bad key, `0xFD` persist fail, `0x01` SOS.
- owner name: CMD `0x42` fragments (same header as Nearby text; blob = UTF-8 1–39 B). TAG sets Meshtastic `owner.long_name` in RAM only. Disconnect / reboot restores `EIXAM_<nodeId>`. Heard NodeInfo names arrive as TEL `0xDB` `[opcode][nodeId u32 LE][utf8]`

## TEL Fragment And Relay Support

The BLE runtime continues to reassemble `0xD0` TEL fragments internally.

Completed `0xD3` live position batches are validated atomically as
`[opcode][count][count × (timeUnix u32 LE + TEL wire12)]`, with count 1–24.
Every embedded TEL is decoded by the same authoritative 12-byte TEL decoder.
Malformed lengths, counts, or TEL records publish no batch and cannot update
current location. Valid batches become one public batch event; only their newest
sample becomes the current connected-device location.

On top of that, the SDK now adds typed support for `0xD2 EIXAM_BLE_TEL_RELAY_RX_V1`.

When a completed aggregate payload matches the `0xD2` contract, the SDK decodes and retains:

- peer TEL payload
- peer decoded position
- `rxSnr`
- `rxRssi`
- self TEL payload
- self decoded position

The latest typed relay sample is exposed through:

- `SdkOperationalDiagnostics.lastTelRelayRx`

This preserves the existing aggregate path while giving host apps a stable typed view when the payload is known.

Firmware ≥ 2.7.54 also copies 6-byte SOS control events (`0xE1` user cancel,
`0xE2` app-cancel ACK, `0xE3` backend `ACK_SOS`) onto TEL. The Dart runtime
treats a TEL copy as the same `sosDeviceEvent` as the SOS characteristic;
duplicates share `rawHex` and are dropped. Hosts must not decode these bytes.

### Relay Ingest Routing

When the relay payload includes a stable remote device identity, the SDK uses
that remote `deviceId` for backend ingest.

The local BLE gateway device remains diagnostics context only.

For integrators this means:

- partner apps do not map relay BLE packets to backend device ids themselves
- relay publish attempts and results are exposed through `SdkOperationalDiagnostics.bridge`

### Relay `422` Handling

Relay-origin telemetry and SOS publishes treat backend `422`/unprocessable
responses as terminal for that publish attempt.

The SDK records that outcome in bridge diagnostics:

- `lastRelayTerminalErrorCode`
- `lastRelayTerminalErrorMessage`

Partner apps may display or log that information, but should not retry relay
ingest independently from the app layer.

## Safety Notes

- Backend/app SOS orchestration remains defined in [`SOS_ORCHESTRATION.md`](SOS_ORCHESTRATION.md)
- BLE command APIs are explicit and only run when the runtime can safely address a connected device
- Partial-channel SOS failures remain non-fatal when another valid SOS channel succeeded

## Deferred / Internal

The SDK intentionally does not expose PROVISION yet.

Reason:

- the payload contract is not stable enough for partner-facing API guarantees
- exposing it now would force host apps to depend on a contract that is likely to change

Until that contract is finalized, provisioning remains internal/deferred by design.

## Design Notes

- Public BLE contract lives in the SDK/runtime layers, not host widgets
- BLE packet parsing stays internal to the Flutter runtime package
- Public models are added only where the SDK can provide a stable typed contract
