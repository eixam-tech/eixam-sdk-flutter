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
- MQTT topic building depends on canonical external user id.

## SOS Backend Paths

| Behavior | Current implementation |
|---|---|
| Trigger | MQTT operational publish in production wiring |
| Cancel | HTTP `POST /v1/sdk/sos/cancel` |
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
  - telemetry publish: `tel/<canonicalExternalUserId>/data`
  - SOS event subscribe: `sos/events/<canonicalExternalUserId>`

## Telemetry Upload Strategy

- Normal telemetry publish uses `MqttTelemetryRepository`.
- BLE-origin telemetry may be published through `BleOperationalRuntimeBridge`.
- Backlog sync:
  - device sends frames over BLE
  - SDK converts records into telemetry payloads
  - backend batch publish happens before ACK back to the device

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
- `packages/eixam_connect_flutter/test/sdk/eixam_connect_sdk_impl_test.dart`
- `packages/eixam_connect_flutter/test/sdk/eixam_connect_sdk_ble_contract_test.dart`
- `packages/eixam_connect_flutter/test/sdk/backlog_sync_controller_test.dart`
- `packages/eixam_connect_flutter/test/data/repositories/in_memory_tracking_repository_test.dart`
- `packages/eixam_connect_flutter/test/mappers/sos_incident_mapper_test.dart`

## Needs Verification

- The repo uses MQTT as the current operational realtime transport, but the project rule still says the final production WebSocket/realtime model is not finalized. Document current code, but avoid treating the MQTT shape as the final platform contract.
