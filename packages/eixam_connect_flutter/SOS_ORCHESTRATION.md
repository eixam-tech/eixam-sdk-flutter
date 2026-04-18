# SOS Orchestration

## Why This Exists

The public SDK SOS API is responsible for producing a coherent safety outcome across the operational backend and the paired physical device.

The orchestration rule is:

`canActivateSos = backendSosAvailable || deviceSosAvailable`

SOS must only be blocked when both channels are unavailable.

## Public SOS Behavior

The public methods `triggerSos(...)`, `cancelSos()`, and `resolveSos()` now orchestrate both channels from the SDK layer.

- Backend remains the preferred operational source when available.
- Device synchronization is automatic when the runtime device path is ready.
- Device synchronization is best-effort when backend already succeeded.
- Device-only fallback is allowed when backend is unavailable and the device path is available.

### `triggerSos(...)`

- Backend available + device available:
  backend SOS is triggered and the device is triggered too.
- Backend available + no device:
  backend SOS is triggered only.
- Backend unavailable + device available:
  device SOS is triggered only and the SDK still treats the request as success.
- Backend unavailable + no device:
  the call fails with `E_SOS_NOT_AVAILABLE`.

### `cancelSos()`

- If backend cancellation is available, it is attempted.
- If the device path is available and the device SOS is still active, the device is cancelled too.
- If backend cancellation fails but device cancellation succeeds, the overall operation still succeeds through the device path.

### `resolveSos()`

- If backend resolve is available, it is attempted.
- If the device path is available and the device SOS is still active, the SDK converges the device to a terminal state using the existing device cancel command.
- If backend resolve fails but the device path succeeds, the overall operation still succeeds through the device path.

## Availability Rules

The SDK keeps separate availability checks for backend and device channels.

### Backend SOS availability

Backend availability is evaluated from the configured runtime:

- MQTT operational SOS:
  requires a signed SDK session and an active realtime connection.
- HTTP-backed SOS repositories:
  require the backend-facing repository/runtime to be configured.
- In-memory and test repositories:
  are treated as backend-available by default.

For trigger flows, backend failures such as missing operational transport or missing required backend prerequisites are treated as backend-unavailable when the SDK decides whether device-only fallback may succeed.

### Device SOS availability

Device SOS is available only when all of the following are true:

- the current `DeviceStatus` is `isReadyForSafety`
- the BLE/runtime command writer is attached
- the requested public action would not duplicate an already-converged device SOS state

## Fallback Matrix

| Backend | Device | Result |
|------|------|------|
| Available | Available | `backendAndDevice` |
| Available | Unavailable | `backendOnly` |
| Unavailable | Available | `deviceOnly` |
| Unavailable | Unavailable | fail with `E_SOS_NOT_AVAILABLE` |

## Source / Channel Exposure

The SDK exposes the channel actually used through `SosDeliveryChannel`.

Values:

- `backendOnly`
- `deviceOnly`
- `backendAndDevice`

Host apps can read it from:

- `SosIncident.deliveryChannel`
  this is returned from public `triggerSos(...)` and `cancelSos()`, and it is also attached to the current incident when the public orchestration owns that cycle.
- `SdkOperationalDiagnostics.lastPublicSosDeliveryChannel`
  this reports the last public SOS channel used by the SDK.

Host apps can also inspect availability through:

- `SdkOperationalDiagnostics.backendSosAvailable`
- `SdkOperationalDiagnostics.deviceSosAvailable`
- `SdkOperationalDiagnostics.canActivateSos`

## Failure Semantics

- If one channel succeeds, the public SOS operation counts as success.
- If backend succeeds and device sync fails, the backend result wins and the device failure is recorded as diagnostics only.
- If backend fails and device succeeds, the SDK returns a successful device-only public result.
- If both channels fail or are unavailable, the public call fails.

## Backward Compatibility

- Phone-only/backend-only flows still work without any device requirement.
- Existing device-specific APIs remain available and are still used internally by the public orchestration.
- Public SOS methods are now richer, but their existing signatures remain unchanged.

## Implementation Notes

- The orchestration lives in `EixamConnectSdkImpl`, not in host widgets.
- Device synchronization reuses `DeviceSosController` through the existing public device SOS methods.
- The SDK keeps a small public SOS overlay so device-only success is reflected in SDK-facing state and incident reads even when the backend repository could not create an incident.
- Device-originated SOS behavior is preserved; the new orchestration only extends public app-origin SOS behavior.
