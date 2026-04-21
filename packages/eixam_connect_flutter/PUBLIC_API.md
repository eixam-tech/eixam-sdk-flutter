# Public API Notes

This guide is intentionally integration-oriented.

It explains what partner apps should call and observe for relay ingest and BLE
backlog sync without moving protocol or orchestration responsibilities out of
the SDK.

## Minimal Host Responsibilities

Partner apps are expected to:

- bootstrap the SDK with the correct `appId` and environment
- set or refresh the signed SDK session
- explicitly connect a compatible BLE device when device-backed features are needed
- render coarse capability/progress from the public SDK state
- optionally expose diagnostics to support or QA users

Partner apps are not expected to:

- decode relay TEL or SOS packets
- map relay BLE payloads to backend device ids
- implement backlog sync protocol state machines
- decide when BLE backlog progress should be ACKed

Those responsibilities stay inside the SDK/runtime layers.

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

## BLE Backlog Sync

The public backlog sync surface is intentionally small:

- `startBacklogSync(...)`
- `cancelBacklogSync()`
- `getBacklogSyncState()`
- `watchBacklogSyncState()`

Lifecycle summary:

1. host app starts backlog sync
2. SDK opens the BLE session with the device
3. device sends typed backlog frames over TEL notify
4. SDK uploads chunk records to the backend in batches
5. SDK ACKs device progress only after backend persistence succeeds
6. SDK exposes coarse progress through `BacklogSyncState`

Useful `BacklogSyncState` fields/getters:

- `phase`
- `confirmedEvents`
- `totalEvents`
- `nextOffset`
- `lastError`
- `isActive`
- `isTerminal`
- `completionFraction`

Reconnect behavior stays SDK-owned:

- if BLE disconnects during an active sync, the SDK restarts with a new sync start request
- backend idempotency remains the duplicate-safety mechanism

## Diagnostics vs State

Use public APIs this way:

- use `BacklogSyncState` for backlog progress
- use `SdkOperationalDiagnostics` for relay/bridge/support diagnostics
- use `SosIncident.deliveryChannel` and SOS capability fields for public SOS UX

Diagnostics are descriptive and support-oriented. They should not replace the
SDK’s typed public state for host control flow.
