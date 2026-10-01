# Public API Notes

This guide is intentionally integration-oriented.

It explains what partner apps should call and observe for relay ingest without
moving protocol or orchestration responsibilities out of the SDK.

## Minimal Host Responsibilities

Partner apps are expected to:

- bootstrap the SDK with the correct `appId` and environment
- set or refresh the signed SDK session
- explicitly connect a compatible BLE device when device-backed features are needed
- read initial `SosLifecycleSnapshot` and `SosCapabilitySnapshot`, subscribe to
  both streams, and render typed lifecycle/capability state
- optionally expose diagnostics to support or QA users

Partner apps are not expected to:

- decode relay TEL or SOS packets

- map relay BLE payloads to backend device ids
- reconstruct SOS lifecycle from history, legacy transport progress, timers, or
  device summaries
- parse `E_SOS_ALREADY_ACTIVE`, select activation transports, or optimistically
  cancel

Those responsibilities stay inside the SDK/runtime layers.

## Connected-device live position batches

`watchResolvedLocation()` remains the latest/current resolved-position stream.
For a connected TAG `0xD3` live batch, only the newest sample updates that
current marker.

`watchDevicePositionBatches()` emits one `EixamDevicePositionBatch` per valid
firmware `0xD3` message. Each batch contains 1–24 real TAG samples in firmware
order (oldest to newest); the SDK does not fabricate or deduplicate samples.
`receivedAt` is phone/SDK reception time, while each sample's nullable
`sampledAt` is the TAG time. `timestampValid` is true only when that TAG Unix
time is within seven days before or ten minutes after reception. This is a
live-transport plausibility safeguard, not proof of RTC synchronization.

Each sample has an opaque SHA-256 `stableSampleKey` over its canonical 16-byte
firmware record for application idempotency. For undated records, replay
identity is necessarily limited to the identity present in those record bytes.
The source is always `SdkLocationSource.connectedDevice`. Classic 12-byte TEL
continues to update current location and does not emit a synthetic batch.

The SDK does not yet expose the firmware `0xD1` persistent-backlog protocol.
Actual live batch density depends on firmware sampling and scheduling; consumers
must use the samples received and must not infer missing intermediate points.

## Relay Ingest

When BLE relay payloads include a stable remote device identity:

- relay telemetry is published using that remote backend `deviceId`
- relay SOS is published using that remote backend `deviceId`
- the gateway/local BLE device remains diagnostics context only

Current public relay visibility:

- `SdkOperationalDiagnostics.lastTelRelayRx`
- `SdkOperationalDiagnostics.bridge`

The bridge diagnostics fields most useful to integrators are:

- `lastRelayRemoteDeviceId`
- `lastRelayTelemetryPublishAttempt`
- `lastRelayTelemetryPublishResult`
- `lastRelaySosPublishAttempt`
- `lastRelaySosPublishResult`
- `lastRelayTerminalErrorCode`
- `lastRelayTerminalErrorMessage`

## Relay `422` Terminal Behavior

For relay-origin ingest only, the SDK treats backend `422`/unprocessable-style
responses as terminal for that publish attempt.

This means:

- the SDK records terminal relay diagnostics
- the SDK does not keep retrying that same relay publish as a transient pending item
- host apps should not add app-side retry logic for the same relay payload

## Diagnostics vs State

Use public APIs this way:

- use `SdkOperationalDiagnostics` for relay/bridge/support diagnostics
- use `SosIncident.deliveryChannel` and SOS capability fields for public SOS UX

Diagnostics are descriptive and support-oriented. They should not replace the
SDK’s typed public state for host control flow.

## SOS lifecycle and capability

Use `getSosLifecycle()` plus `sosLifecycleStream` and `getSosCapability()` plus
the capability stream for the initial and ongoing contract. Lifecycle owns
idle through terminal/failure/recovery states; capability independently reports
whether app/backend or connected-device activation and current cancellation are
available.

App/backend activation does not require a registered device, BLE, command
channel, firmware runtime, telemetry, tracking, or a location fix. The SDK owns
transport selection, countdown and dispatch ordering, bounded already-active
recovery, cancellation confirmation, account-scoped persistence, and revision
ordering. Host consumers merge equal revisions and reject stale ones.

See [SOS orchestration](SOS_ORCHESTRATION.md) and the repository
[authoritative lifecycle architecture](../../docs/SOS_LIFECYCLE_ARCHITECTURE_2026.md).

## Nearby LoRa text

`sendNearbyBroadcastText(String)` writes UTF-8 to the connected TAG. The TAG
broadcasts on mesh port 262 (hop 0, PRIMARY PSK). `sendNearbyDirectText` is a
PKI 1:1 (needs dest public key already on the TAG). `sendNearbyGroupText`
uses a SECONDARY PSK installed with `setNearbyGroup` — never a PRIMARY swap.
`NearbyGroupCommandResult.slotsFull` is REJECT detail `0xFF` (7 SECONDARY slots).
`setNearbyGroup(..., replace: true)` wipes tag groups when full (action 2).
`setNearbyGroup` retries once on ACK timeout while the TAG stays connected.
`badKey` is `0xFE`, `persistFailed` is `0xFD`, `sosBlocked` is `0x01`.
`watchNearbyText()` emits incoming messages with dest / groupId / pki flag.
`watchNearbyTextTxStatus()` emits every `0xDA`, including later delivery ACKs
(`meshAck` / `recipientAck` / `ackTimeout` / `gotNak`) for a packet already
returned by send. Correlate by `packetId`. Firmware ≥ **2.7.63**. PKI DMs set
`want_ack`; plaza/group stay hop 0 and get an explicit hop-0 ROUTING ACK from
a nearby receiver (SNR-staggered; later nodes cancel if they overhear one).
`watchNearbyNodeNames()` emits NodeInfo `long_name` heard by the connected TAG
(`0xDB`). That is the display name of the phone currently on that TAG, or
`EIXAM_<nodeId>` when nobody is connected. `setNearbyOwnerDisplayName` pushes
this phone's profile name onto the TAG (`0x42`, 1–39 UTF-8 bytes). Empty names
are ignored. Cached and resent on the next connect. Old firmware that ignores
`0x42` still advertises `EIXAM_<nodeId>`.

Text caps: 231 B UTF-8 for plaza and group (`tooLong` above that; the mesh
`Data` protobuf costs 8 B and 233 B would not fit the LoRa frame), 200 B for
PKI DMs.

Hosts persist messages. The SDK does not. There is no cellular fallback.
`NearbyTextTxStatus.timeout` means the TAG never answered `0xDA`.
Native protection keeps the GATT link in background and still carries Nearby:
writes go through the native command owner, and TEL notifies are forwarded to
Dart (`telNotifyReceived`). Hosts should not treat protection as a Nearby lock.
Firmware ≥ **2.7.56** is required; 2.7.55 plaza-only framing is not compatible.
Firmware ≥ **2.7.57** enforces the 231 B cap and ignores SECONDARY group keys
on TEL/SOS/cluster ports. Firmware ≥ **2.7.58** for owner-name `0x42` / `0xDB`.
