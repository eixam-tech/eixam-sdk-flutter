# Backend Integration

## Signed Session

- Session model: `packages/eixam_connect_core/lib/src/config/eixam_session.dart`
- Session storage/context:
  - `data/datasources_local/sdk_session_store.dart`
  - `data/datasources_remote/sdk_session_context.dart`
- HTTP auth headers are built by `SdkHttpTransport`:
  - `X-App-ID`
  - `X-User-ID`
  - `Authorization: Bearer <userHash>`

## Identity Canonicalization

- `HttpSdkIdentityRemoteDataSource.bootstrapSession(...)` calls `/v1/sdk/me`.
- It enriches the session with:
  - `sdkUserId`
  - `canonicalExternalUserId`
- MQTT topic building depends on `sdkUserId` from `GET /v1/sdk/me`.

## SOS Backend Paths

| Behavior | Current implementation |
|---|---|
| Trigger | MQTT operational publish in production wiring |
| Cancel | MQTT `cancel: true` on `sos/alerts/<sdkUserId>` (durable outbox; see below) |
| Resolve | HTTP `POST /v1/sdk/sos/resolve` |
| Get active SOS | HTTP `GET /v1/sdk/sos` |

- HTTP trigger path also exists in `HttpSosRemoteDataSource` with `POST /v1/sdk/sos`, but production factory wiring currently uses `MqttOperationalSosRepository` for trigger flow.

## SOS Cancel / Resolve Semantics

- `MqttOperationalSosRepository`:
  - requires an active incident for cancel/resolve
  - persists local state
  - settles using returned incident when available
  - otherwise rechecks `getActiveSos()` and falls back to local terminal state if backend reports no active incident

## MQTT Topics

- Built in `sdk/sdk_mqtt_contract.dart`.
- Current patterns:
  - telemetry publish: `tel/<sdkUserId>/data`
  - SOS publish: `sos/alerts/<sdkUserId>`
  - SOS event subscribe: `sos/events/<sdkUserId>`

### SOS cancel payload: `ageMs` (optional)

The operational SOS cancel on `sos/alerts/<sdkUserId>` carries an optional
integer `ageMs` next to the existing fields. Trigger payloads (and every other
publish) never carry it; nothing changes on HTTP.

Cancel (published 4.2 s after the cancel was created on the phone):

```json
{"timestamp":"2026-11-16T12:00:05.000Z","cancel":true,"ageMs":4200}
```

Trigger (no `ageMs`):

```json
{"timestamp":"2026-11-16T12:00:00.000Z","identitySource":"app","triggerSource":"commercial_app"}
```

(`userId` is added on legacy user topics, as before.)

- `ageMs` = milliseconds elapsed since the cancel was created on the phone,
  recomputed at each publish attempt (first publish, every outbox retry, and
  after an app restart).
- In-process it is measured with a monotonic clock, so wall-clock changes on the
  phone cannot skew it. After a restart there is no monotonic reference: it is
  wall-clock now − the persisted creation time.
- Always an integer >= 0 (a wall clock moved backwards yields 0). No explicit
  cap: a cancel older than the outbox `cancelMaxAge` (24 h) expires instead of
  being published.
- The backend dates the cancel as server receive time − `ageMs`.
- `timestamp` (the phone's wall-clock creation time) is kept unchanged for older
  backends; `cancel: true` is unchanged.
- Code: `SdkMqttContract.buildOperationalSosCancelEnvelope`,
  `SosDeliveryOutbox.ageMsOf`.

## Telemetry Upload Strategy

- Normal telemetry publish uses `MqttTelemetryRepository`.
- BLE-origin telemetry may be published through `BleOperationalRuntimeBridge`.

## Offline / Reconnect Behavior

- `MqttRealtimeClient` reconnects after disconnect unless manually stopped or session is absent.
- `BleOperationalRuntimeBridge` keeps pending operational telemetry/SOS items and flushes when realtime becomes publishable.
- Relay-origin terminal `422` responses are not retried as transient pending items.
- `MqttOperationalSosRepository.rehydrateRuntimeStateFromBackend()` keeps recent local fallback state during a short destructive rehydration grace period.

## Device Registry Integration

- Registry endpoints:
  - `GET /v1/sdk/devices`
  - `POST /v1/sdk/devices`
  - `DELETE /v1/sdk/devices/<id>`
- SDK auto-sync logic in `EixamConnectSdkImpl` only runs when it can resolve a canonical hardware id safely.

## Main Files

- `packages/eixam_connect_flutter/lib/src/sdk/api_sdk_factory.dart`
- `packages/eixam_connect_flutter/lib/src/data/datasources_remote/sdk_http_transport.dart`
- `packages/eixam_connect_flutter/lib/src/data/datasources_remote/sdk_identity_remote_data_source.dart`
- `packages/eixam_connect_flutter/lib/src/data/datasources_remote/http_sos_remote_data_source.dart`
- `packages/eixam_connect_flutter/lib/src/data/repositories/mqtt_operational_sos_repository.dart`
- `packages/eixam_connect_flutter/lib/src/sdk/mqtt_realtime_client.dart`
- `packages/eixam_connect_flutter/lib/src/sdk/ble_operational_runtime_bridge.dart`
- `packages/eixam_connect_flutter/lib/src/data/repositories/api_sdk_device_registry_repository.dart`

## Related Tests

- `packages/eixam_connect_flutter/test/sdk/eixam_bootstrap_resolver_test.dart`
- `packages/eixam_connect_flutter/test/sdk/sos_lifecycle_matrix_test.dart`
- `packages/eixam_connect_flutter/test/sdk/sdk_mqtt_contract_identity_test.dart`
- `packages/eixam_connect_flutter/test/data/repositories/in_memory_tracking_repository_test.dart`
- `packages/eixam_connect_flutter/test/mappers/sos_incident_mapper_test.dart`

## Needs Verification

- The repo uses MQTT as the current operational realtime transport, but the project rule still says the final production WebSocket/realtime model is not finalized. Document current code, but avoid treating the MQTT shape as the final platform contract.
