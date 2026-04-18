# BLE Device Contract

## Why This Exists

The Flutter SDK is responsible for hiding the EIXAM BLE protocol from host apps. Host apps should call typed SDK APIs for SOS, device control, runtime inspection, and typed relay telemetry instead of sending raw BLE commands or decoding packets themselves.

## Public SOS Diagnostics And Availability

Host apps can read SOS channel readiness and the most recent public delivery path from `SdkOperationalDiagnostics`:

- `backendSosAvailable`
- `deviceSosAvailable`
- `canActivateSos`
- `lastPublicSosDeliveryChannel`

The actual incident channel is also exposed on `SosIncident.deliveryChannel`.

Possible delivery values:

- `backendOnly`
- `deviceOnly`
- `backendAndDevice`

This keeps SOS routing explicit for host UX, incident history, and support diagnostics.

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

### Reboot

- `rebootDevice()` maps to protocol command `0x22 REBOOT`
- the SDK only attempts it when a connected command-capable device exists

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
- malformed or unsupported payloads are ignored safely until timeout

## TEL Fragment And Relay Support

The BLE runtime continues to reassemble `0xD0` TEL fragments internally.

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
