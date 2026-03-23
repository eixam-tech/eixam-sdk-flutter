# BLE provider integration notes

This package includes a BLE-oriented runtime abstraction used by the device module.

## Included building blocks
- `BleClient`: low-level BLE adapter contract
- `MockBleClient`: demo BLE environment for local development
- `BleDeviceRuntimeProvider`: device lifecycle orchestration built on top of a BLE client

## Protocol handling in the runtime layer
- TEL notifications on `ea01` can be either classic 10-byte TEL position packets or `0xD0` aggregate fragments.
- SOS notifications on `ea02` can be classic 10-byte mesh packets, classic 5-byte minimal mesh packets, or 4-byte device event packets.
- TEL aggregate reassembly lives in `BleDeviceRuntimeProvider` via `EixamTelReassembler`, not in the UI layer.
- The UI should consume typed `BleIncomingEvent` values and avoid assuming packet shape from payload length alone.

## Event typing
- `telPosition`: classic decoded 10-byte TEL packet
- `telAggregateFragment`: one `0xD0` TEL aggregate fragment
- `telAggregateComplete`: a fully reassembled TEL aggregate blob
- `sosMeshPacket`: classic decoded SOS mesh packet
- `sosDeviceEvent`: 4-byte SOS device control event
- `unknownProtocolPacket`: payload did not match a currently supported protocol packet

## Preferred device and reconnect behavior
- The SDK stores one preferred BLE device after a successful full connection.
- On SDK startup and app resume, the SDK attempts to reconnect to that preferred device when manual disconnect is not active.
- Unexpected foreground disconnects schedule reconnect retries with simple backoff.
- Manual disconnect disables auto-reconnect until the user explicitly starts a new connect flow.
- Reconnect currently reuses the existing scan-plus-selected-device flow by stored device identifier; it does not rely on background BLE transport or a platform daemon.

## Recommended next step for production
Create a `FlutterBluePlusBleClient` (or equivalent) that implements `BleClient` and then inject it into `BleDeviceRuntimeProvider`.

## Why this matters
The host app and the public SDK should not depend directly on a Bluetooth package. Keeping BLE behind `BleClient` makes the stack easier to test, replace and maintain.

## Native prerequisites
Check `NATIVE_PERMISSIONS_CHECKLIST.md` before enabling any real BLE feature in the host app.
