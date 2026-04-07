# Real Backend Validation Checklist

Use this checklist with the demo app validation console when validating the
current SDK against a real backend. The app remains a thin host; all business
and operational behavior should be observed through SDK diagnostics and runtime
surfaces.

## 1. Backend Environment And Session Bootstrap

- In local debug builds, first-run validation defaults are prefilled with:
  - `http://127.0.0.1:8080`
  - `tcp://127.0.0.1:1883`
  - `app_localandroid01`
  - `roger-android-local-01`
  - `8a59d9fce6ef5d541bbb7fe14d0ada32a0551f7a3152dbe9bb5a410b7ca58e9e`
- Saved backend configuration still wins over those defaults.
- The validation console can reload them with `Load local debug defaults` /
  `Reset to local defaults`.
- Select the intended backend environment in the validation console and confirm:
  - HTTP base URL
  - MQTT URL
  - selected preset / active backend readout
- Run `setSession(...)` with a real signed session.
- Confirm the console shows:
  - signed session status = configured
  - canonical identity status = resolved from `/v1/sdk/me`
  - canonical `external_user_id`
  - SDK user id
- If bootstrap fails, inspect:
  - last identity/auth error
  - SOS rehydration note
  - last action error

## 2. MQTT Connectivity And Topic Readiness

- Confirm the console shows:
  - MQTT connection state
  - MQTT subscription status
  - current SOS topic subscription
  - current TEL publish topic
- Expected sequence:
  - canonical identity resolved first
  - MQTT topics become available
  - connection state becomes `connected`
- If MQTT does not connect:
  - compare environment URLs with the intended backend
  - inspect the last realtime payload/event and last bridge decision

## 3. SOS Trigger / ACK / Cancel

- Trigger SOS from the validation console.
- Confirm:
  - current SOS state changes out of `idle`
  - incident id is shown
  - pending SOS is visible if MQTT is unavailable
  - last SOS incident snapshot is populated
- Validate backend lifecycle handling:
  - `sos_ack` should route as `SOS_ACK` for local-origin SOS
  - relay-origin SOS should show a routing summary that includes relay context
  - explicit or transformed `SOS_ACK_RELAY(nodeId)` should only appear for
    active relay-origin SOS
- Cancel SOS and confirm final state reflects backend/runtime behavior, not only
  local button presses.

## 4. SOS Rehydration After Restart

- Trigger or keep an SOS active in backend.
- Restart the app/SDK or refresh the session.
- Confirm:
  - current SOS state is reconstructed correctly
  - the SOS rehydration note is either empty/benign or explains fallback
    behavior
- Repeat with no active incident and confirm the SDK returns to `idle`.

## 5. TEL Publish

- Publish a manual telemetry sample from the validation console.
- Confirm:
  - telemetry publish topic is present
  - telemetry publish status becomes ready/published
  - last published telemetry sample matches the request
- If MQTT is offline:
  - pending telemetry should become visible
  - after reconnect, only the latest pending sample should flush

## 6. TEL Aggregate Behavior

- For supported aggregate-complete payloads:
  - confirm telemetry is published through the existing backend telemetry
    contract
- For incomplete aggregate fragments:
  - confirm nothing is published early
  - confirm diagnostics mention buffering/waiting for completion
- For unsupported aggregate-complete payloads:
  - confirm nothing is silently published
  - confirm diagnostics explain that the payload does not fit the current
    telemetry contract

## 7. Reconnect / Offline Behavior

- Drop MQTT connectivity while the app remains active.
- Confirm:
  - connection state changes away from `connected`
  - pending telemetry and/or pending SOS become visible when applicable
  - last bridge decision explains buffering or retry behavior
- Restore connectivity and confirm:
  - pending items flush once
  - diagnostics update accordingly

## 8. Quick Failure Readout

When something fails, capture these fields from the validation console first:

- selected preset / active backend
- signed session status
- canonical identity status
- MQTT connection state
- current SOS topic subscription
- current TEL publish topic
- SOS routing summary
- telemetry publish status
- last bridge decision
- last identity/auth error
- last action error
- SOS rehydration note
