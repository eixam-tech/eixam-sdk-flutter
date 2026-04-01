# Debug App Validation Guide

For a shorter operator-facing real backend runbook, see
`docs/app_ble/REAL_BACKEND_VALIDATION_CHECKLIST.md`.

## Purpose

This guide describes how to validate the current SDK to backend integration using the internal reference/debug app.

It is intended for:

- internal QA
- SDK validation sessions
- backend/mobile integration debugging

It is practical and test-oriented on purpose.

## Validation Scope

Current validation areas:

- signed session setup
- `/v1/sdk/me` identity enrichment
- MQTT connectivity
- SOS trigger / cancel / lifecycle
- telemetry publish
- contacts CRUD
- backend device registry CRUD
- local runtime device status
- BLE runtime to backend bridge behavior

## Before You Start

Confirm:

- backend environment is available
- MQTT endpoint is reachable
- test account can receive a signed SDK session
- reference app is using the current SDK packages from this monorepo
- BLE test device is available if runtime device validation is needed

## 1. Validate Signed Session

Expected host-side setup:

- app obtains `appId`
- app obtains external user id
- app obtains signed `userHash`
- app calls `sdk.setSession(...)`

What to verify:

- no `E_SDK_SESSION_REQUIRED` errors
- realtime state begins moving out of fully idle/disconnected after session setup
- session-dependent surfaces become usable

If session setup fails:

- inspect partner/backend signing flow
- inspect app wiring before SDK calls
- verify logout is not clearing session immediately after setup

## 2. Validate `/v1/sdk/me`

After `setSession(...)`, the SDK should call:

- `GET /v1/sdk/me`

What to verify:

- backend returns valid `user.id`
- backend returns canonical `user.external_user_id`
- MQTT topic usage reflects canonical identity, not raw host identity

Practical checks:

- watch SDK logs around session bootstrap
- inspect MQTT subscription topic built for SOS events
- inspect telemetry topic built for TEL publish

If it fails:

- check auth headers
- check backend JSON shape
- confirm canonical `external_user_id` is non-empty

## 3. Verify MQTT Connectivity

The SDK currently tracks:

- `connecting`
- `connected`
- `reconnecting`
- `disconnected`
- `error`

What to verify:

- session setup causes MQTT connect attempt
- active session uses current backend environment
- reconnect occurs after temporary disconnect
- `clearSession()` tears MQTT down cleanly

Useful checks:

- observe realtime connection state in the app validation surfaces
- inspect MQTT connection logs
- inspect that event subscriptions use `sos/events/{segment}`

## 4. Test SOS Trigger / Cancel / Events

### App-initiated SOS

Use the app surface that calls:

- `sdk.triggerSos(SosTriggerPayload(...))`

Verify:

- publish goes to `sos/alerts`
- QoS 1, retain false at the transport layer
- payload includes timestamp and coordinates

### Cancel

Use the app surface that calls:

- `sdk.cancelSos()`

Verify:

- HTTP request goes to `POST /v1/sdk/sos/cancel`
- request has auth headers only
- request sends no body

Important:

- do not expect HTTP cancel to become final lifecycle state by itself
- final cancelled state must still come from MQTT lifecycle event

### MQTT lifecycle events

Verify:

- SDK receives SOS lifecycle event on `sos/events/{segment}`
- SOS state stream changes only after backend event
- final cancelled/resolved/acknowledged state follows MQTT input

## 5. Test Telemetry Publish

### App-initiated telemetry

Use a surface that calls:

- `sdk.publishTelemetry(...)`

Verify:

- topic is `tel/{segment}/data`
- canonical user identity is reflected in the topic segment
- payload includes timestamp, latitude, longitude, altitude

### BLE-originated telemetry

With a connected BLE device producing TEL packets, verify:

- TEL packets are decoded in runtime
- the bridge publishes telemetry only when minimum valid fields exist
- repeated duplicate packets do not flood publishes

## 6. Test Contacts

Use the contacts validation surface.

Verify:

- create contact works
- list contact works
- update contact works
- delete contact works

Current expected contact fields:

- `id`
- `name`
- `phone`
- `email`
- `priority`
- `createdAt`
- `updatedAt`

If UI or API expects fields like `active`, that is stale behavior and should be removed or isolated outside the public contract.

## 7. Test Backend Device Registry

Use the device registry validation surface if available, or call the SDK facade directly.

Verify:

- `listRegisteredDevices()`
- `upsertRegisteredDevice(...)`
- `deleteRegisteredDevice(id)`

Confirm the result is backend registry data, not live BLE state.

Expected backend-aligned fields:

- `id`
- `hardwareId`
- `firmwareVersion`
- `hardwareModel`
- `pairedAt`
- `createdAt`
- `updatedAt`

## 8. Test Runtime Device Status

Connect a BLE device through the debug app.

Verify:

- `connectDevice(...)` updates runtime state
- `deviceStatusStream` reflects current device lifecycle
- preferred device is stored after successful operational use
- `disconnectDevice()` clears runtime connection state cleanly

Important:

- runtime device state is not backend registry state
- backend registry validation should be tested separately

## 9. Test BLE Runtime To Backend Bridge

With BLE producing runtime events:

### TEL

Verify:

- decoded TEL event reaches the bridge
- telemetry is published when MQTT is available
- if MQTT is unavailable, only the latest telemetry sample is retained
- after reconnect, the latest retained telemetry is published once

### SOS

Verify:

- decoded BLE SOS with coordinates reaches the bridge
- SOS is published when MQTT is available
- if MQTT is unavailable, a single pending SOS trigger is retained
- after reconnect, the pending SOS is published once

### Device confirmations

Verify backend realtime events can drive:

- `POS_CONFIRMED`
- `SOS_ACK`
- `SOS_ACK_RELAY`

Inspect BLE/device command debug logs when these are expected.

## 10. Failure Debugging Checklist

When something fails, inspect in this order:

1. Session exists and is current
2. `/v1/sdk/me` canonical identity succeeded
3. MQTT connection state
4. actual MQTT topic being used
5. BLE packet decode success
6. bridge retain/flush behavior
7. backend realtime lifecycle/ack event shape
8. device command write readiness

## Useful Signals To Inspect

### Identity issues

Look for:

- session missing
- canonical external user id missing
- `/v1/sdk/me` invalid response

### MQTT issues

Look for:

- transport stuck in reconnecting/error
- no active session
- topic mismatch with canonical identity

### BLE issues

Look for:

- no decoded TEL/SOS events
- duplicate suppression hiding repeated packets
- no position present in BLE SOS packet

### Bridge issues

Look for:

- pending telemetry retained but never flushed
- pending SOS retained but never flushed
- session cleared before flush
- bridge reset after session change

### Device confirmation issues

Look for:

- backend realtime event shape does not clearly indicate confirmation type
- relay node id missing for `SOS_ACK_RELAY`
- device command channel not ready

## Known Current Limitations

- BLE SOS packets without coordinates are not currently publishable as backend SOS trigger
- relay ACK routing now follows active runtime SOS context:
  local-origin SOS expects `SOS_ACK`, relay-origin SOS expects `SOS_ACK_RELAY(nodeId)`, and mismatched relay ACK events are ignored with diagnostics
- offline resilience is in-memory only for this iteration
- telemetry is latest-sample-wins, not full queued replay

These are known product/runtime limits, not random bugs.
