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
