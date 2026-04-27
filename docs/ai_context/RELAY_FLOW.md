# Relay Flow

## Own-Device SOS vs Remote-Node SOS

- Own-device SOS:
  - comes from the currently connected runtime device
  - device and backend identity are local to that paired runtime path
- Remote-node / relay SOS:
  - arrives through a gateway device over BLE mesh/relay payloads
  - should be treated as a remote incident when a stable remote `deviceId` is present

## How Relay Classification Works

- Relay telemetry decode:
  - `device/eixam_tel_relay_rx_packet.dart`
  - surfaced as `SdkOperationalDiagnostics.lastTelRelayRx`
- Relay SOS classification uses:
  - `relayCount > 0`
  - remote device identity when present
  - `EixamConnectSdkImpl._relayContextFrom(...)`
  - `BleOperationalRuntimeBridge`
- Cluster aggregate relay packets are parsed, but current bridge logic skips backend publish when member payloads do not carry backend-safe remote IDs.

## Backend Routing Rules

- When relay payload includes a stable remote device identity:
  - telemetry is published using the remote backend `deviceId`
  - SOS is published using the remote backend `deviceId`
  - local gateway device remains diagnostics context only
- When the identity is missing:
  - relay telemetry publish is skipped
  - cluster aggregate member publish is skipped

## Relay Acknowledgment Behavior

- The BLE operational bridge can transform backend SOS acknowledgment into relay ACK behavior for an active relay SOS context.
- Explicit relay ACKs are accepted only when they match the active relay context.
- If active SOS context is local-origin, relay ACK is ignored.

## Terminal `422` Handling

- Relay-origin telemetry and SOS treat backend `422`/unprocessable responses as terminal for that publish attempt.
- SDK records:
  - `lastRelayTerminalErrorCode`
  - `lastRelayTerminalErrorMessage`
- Host apps should not add app-side retry for the same relay payload.

## What The App Should Display

- Use typed public state and diagnostics.
- Good surfaces for host UI/support:
  - `SdkOperationalDiagnostics.lastTelRelayRx`
  - `SdkOperationalDiagnostics.bridge`
  - public SOS state / incident state
- The app should not infer backend routing from raw BLE bytes.

## What Must Remain SDK-Owned

- Remote-device ID routing
- Relay ingest deduplication
- Terminal `422` handling
- Backend retry / pending operational item behavior
- Relay ACK translation rules

## Main Files

- `packages/eixam_connect_flutter/lib/src/sdk/ble_operational_runtime_bridge.dart`
- `packages/eixam_connect_flutter/lib/src/sdk/relay_ingest_context.dart`
- `packages/eixam_connect_flutter/lib/src/sdk/eixam_connect_sdk_impl.dart`
- `packages/eixam_connect_flutter/lib/src/device/eixam_tel_relay_rx_packet.dart`
- `packages/eixam_connect_flutter/lib/src/device/eixam_tel_relay_cluster_packet.dart`
- `packages/eixam_connect_core/lib/src/entities/device_tel_relay_rx.dart`
- `packages/eixam_connect_core/lib/src/entities/sdk_bridge_diagnostics.dart`

## Related Tests

- `packages/eixam_connect_flutter/test/device/eixam_tel_relay_rx_packet_test.dart`
- `packages/eixam_connect_flutter/test/device/eixam_tel_relay_cluster_packet_test.dart`
- `packages/eixam_connect_flutter/test/device/eixam_sos_packet_test.dart`
- `packages/eixam_connect_flutter/test/sdk/eixam_connect_sdk_impl_test.dart`
- `packages/eixam_connect_flutter/test/sdk/eixam_connect_sdk_ble_contract_test.dart`

## Needs Verification

- The docs and code clearly define relay ingest behavior, but the exact partner UX wording for a remote-node SOS screen is not defined in this repo. Keep rendering based on typed SDK state/diagnostics, not custom app logic.
