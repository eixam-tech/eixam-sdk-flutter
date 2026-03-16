# BLE provider integration notes

This starter now includes a BLE-oriented runtime abstraction used by the device module.

## Included building blocks
- `BleClient`: low-level BLE adapter contract
- `MockBleClient`: demo BLE environment for local development
- `BleDeviceRuntimeProvider`: device lifecycle orchestration built on top of a BLE client

## Recommended next step for production
Create a `FlutterBluePlusBleClient` (or equivalent) that implements `BleClient` and then inject it into `BleDeviceRuntimeProvider`.

## Why this matters
The host app and the public SDK should not depend directly on a Bluetooth package. Keeping BLE behind `BleClient` makes the stack easier to test, replace and maintain.

## Native prerequisites
Check `NATIVE_PERMISSIONS_CHECKLIST.md` before enabling any real BLE feature in the host app.
