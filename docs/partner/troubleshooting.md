# Troubleshooting

## `customEndpoints` rejected

Cause: `customEndpoints` were passed while using `production`, `sandbox`, or `staging`.

Fix: only pass `customEndpoints` with `EixamEnvironment.custom`.

## `initialSession.appId` mismatch

Cause: the bootstrap `appId` and the provided signed session `appId` do not match.

Fix: make both values identical.

## Signing flow confusion

Cause: the mobile app is trying to hold the app secret or compute `userHash` locally.

Fix:

- keep the app secret on the partner backend only
- generate or obtain `userHash` on the backend for `appId` + `externalUserId`
- pass the resulting signed session to the mobile app
- use `/v1/auth/sign` only for internal staging validation, not for partner production architecture

## Realtime URI looks non-websocket

Cause: the public field is named `websocketUrl`, but the configured broker may use a different transport scheme.

Fix: this is expected. Depending on environment/client transport, the broker URI may be `ssl://`, `tls://`, `tcp://`, `ws://`, or `wss://`.

## Bootstrap did not request permissions

Expected behavior. Permission requests remain explicit host-app actions.

## Bootstrap did not pair a device

Expected behavior. Device pairing/connection remains an explicit host-app decision.

## Protection readiness is blocked

Inspect:

- session availability
- paired/connected device state
- Bluetooth enabled state
- location permission
- notification permission
- platform capability readiness

## iOS Protection coverage remains partial

This can be expected depending on current iOS runtime ownership support.

## Realtime appears incomplete

Current realtime may still depend on backend protocol maturity. Use runtime diagnostics and current agreed backend transport behavior as the source of truth.

## MQTT auth fails after copying HTTP headers

Cause: the client or backend guidance is still treating MQTT auth like HTTP auth or old MQTT 5 User Properties.

Fix:

- keep HTTP as `Authorization: Bearer <userHash>`
- use MQTT `username = sdk:<appId>:<externalUserId>`
- use MQTT `password = <userHash>`
- do not send a `Bearer` prefix in MQTT
