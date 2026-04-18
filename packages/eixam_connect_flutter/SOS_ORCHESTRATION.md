# SOS Orchestration

## Why This Exists

The public SDK SOS API is responsible for producing a coherent safety outcome across the operational backend and the paired physical device.

The orchestration rule is:

`canActivateSos = backendSosAvailable || deviceSosAvailable`

SOS must only be blocked when both channels are unavailable.

The SDK keeps two different truths separate:

- current SOS capability:
  what the SDK can use right now if the host app asks to trigger SOS
- effective delivery channel:
  what the SDK actually used for the active or last public SOS operation

## Public SOS Behavior

The public methods `triggerSos(...)`, `cancelSos()`, and `resolveSos()` now orchestrate both channels from the SDK layer.

- Backend remains the preferred operational source when available.
- Device synchronization is automatic when the runtime device path is ready.
- Device synchronization is best-effort when backend already succeeded.
- Device-only fallback is allowed when backend is unavailable and the device path is available.

### `triggerSos(...)`

- The SDK re-evaluates device availability at execution time before choosing channels.
- Backend available + device available:
  backend SOS is triggered and the device is triggered too.
  Effective delivery is `backendAndDevice`.
- Backend available + no device:
  backend SOS is triggered only.
  Effective delivery is `backendOnly`.
- Backend unavailable + device available:
  device SOS is triggered only and the SDK still treats the request as success.
  Effective delivery is `deviceOnly`.
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

Device SOS capability is evaluated from the live runtime SOS command path, not
from generic device readiness and not only from the last historical delivery.

For public SOS orchestration, device SOS is available only when all of the following are true:

- the current runtime reports the device as connected
- the connected device is EIXAM-compatible
- the BLE/runtime has a live SOS command write path
- the requested public action would not duplicate an already-converged device SOS state

The SDK does not require broader readiness conditions that are unrelated to
app-to-device SOS command delivery.

The SOS command path is defined by the same route used during execution for:

- `0x06 SOS_TRIGGER_APP`
- `0x04 SOS_CANCEL`
- `0x05 SOS_CONFIRM`

If those commands are writable through INET, the SDK treats the device SOS path
as available even if CMD is not required for that operation.

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
- `SdkOperationalDiagnostics.currentSosCapabilityChannel`
- `SdkOperationalDiagnostics.currentSosCapabilityLabel`

This means host apps can render both:

- current capability:
  backend only, device only, backend + device, or unavailable
- actual delivery:
  backendOnly, deviceOnly, or backendAndDevice for the active or last public SOS cycle

`lastPublicSosDeliveryChannel` remains historical only. It must not be used as
the current capability truth for whether the next SOS action can use backend,
device, or both.

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
- The SDK uses one internal device SOS-path helper for public execution and diagnostics so capability and execution cannot drift apart.
- Public SOS execution refreshes device capability from the live runtime before choosing channels, so stale cached status does not incorrectly downgrade a connected command-capable device.
- The SDK keeps a small public SOS overlay so device-only success is reflected in SDK-facing state and incident reads even when the backend repository could not create an incident.
- Device-originated SOS behavior is preserved; the new orchestration only extends public app-origin SOS behavior.
