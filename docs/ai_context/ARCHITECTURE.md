# Architecture

## High-Level Shape

| Layer | Role | Main locations |
|---|---|---|
| EIXAM SOS Core | Public contracts, entities, enums, state machines, SDK interface | `packages/eixam_connect_core/lib/src` |
| EIXAM Connect SDK | Concrete Flutter/runtime implementation | `packages/eixam_connect_flutter/lib/src` |
| Backend integration | HTTP, MQTT, signed session, device registry, contacts | `packages/eixam_connect_flutter/lib/src/data` and `lib/src/sdk` |
| BLE/device runtime | Pairing, reconnect, notifications, packet parsing, SOS device state | `packages/eixam_connect_flutter/lib/src/device` |

## EIXAM SOS Core

- `packages/eixam_connect_core` is the stable contract layer.
- Main concerns:
  - SDK interface: `interfaces/eixam_connect_sdk.dart`
  - public config/session models
  - `SosState`, `DeviceSosState`, `DeathManStatus`, `RealtimeConnectionState`
  - `SosStateMachine` and `DeathManStateMachine`
  - public entities like `SosIncident`, `DeviceStatus`, `DeviceRuntimeStatus`, `SdkOperationalDiagnostics`

## EIXAM Connect SDK

- `packages/eixam_connect_flutter/lib/src/sdk/eixam_connect_sdk_impl.dart` is the orchestration center.
- It composes:
  - SOS repository
  - telemetry repository
  - device repository
  - notifications repository
  - realtime client
  - `DeviceSosController`
  - BLE operational bridge
  - protection mode adapter/controller
- `api_sdk_factory.dart` builds production-like HTTP + MQTT + BLE wiring.

## Backend Integration

- Signed SDK session is stored and propagated through:
  - `SdkSessionStore`
  - `SdkSessionContext`
  - `HttpSdkIdentityRemoteDataSource`
- Production bootstrap path:
  - `EixamConnectSdk.bootstrap(...)`
  - `EixamBootstrapResolver`
  - `ApiSdkFactory.createHttpApi(...)`
- Main backend-facing components:
  - SOS HTTP: `data/datasources_remote/http_sos_remote_data_source.dart`
  - authenticated HTTP transport: `data/datasources_remote/sdk_http_transport.dart`
  - contacts: `sdk_contacts_remote_data_source.dart`
  - device registry: `sdk_devices_remote_data_source.dart`
  - MQTT realtime and operational publish: `sdk/mqtt_realtime_client.dart`, `sdk/sdk_mqtt_contract.dart`

## BLE / Device Runtime

- BLE runtime ownership stays in the SDK/runtime layer.
- Main components:
  - `device/ble_device_runtime_provider.dart`
  - `device/device_sos_controller.dart`
  - `sdk/ble_auto_reconnect_coordinator.dart`
  - `data/repositories/in_memory_device_repository.dart`
- Responsibilities:
  - compatibility check after connect/service discovery
  - notification subscription
  - TEL fragment reassembly
  - typed packet decoding
  - device-origin SOS tracking
  - command readiness / command sending
  - reconnect and preferred device behavior

## MQTT / Realtime

- MQTT is currently the operational realtime transport in production wiring.
- `MqttRealtimeClient`:
  - subscribes to SOS event topics
  - publishes telemetry
  - publishes operational SOS
  - reconnects when session changes or transport drops
- `BleOperationalRuntimeBridge` connects BLE-origin events to backend publish paths.

## Where Logic Should Live

| Concern | Owner |
|---|---|
| Public SDK contract, state models | `eixam_connect_core` |
| SOS orchestration across backend + device | `eixam_connect_flutter` |
| BLE protocol parsing and packet classification | `eixam_connect_flutter` |
| Relay ingest routing and retry policy | `eixam_connect_flutter` |
| DMP monitoring and escalation | `eixam_connect_flutter` |
## Architecture Rules To Preserve

- The app should remain thin.
- The app should render typed SDK state and call SDK APIs.
- Business-critical behavior should not move into widgets.
- BLE raw bytes and relay mapping stay SDK-owned.
- Current MQTT usage exists, but the repo rule still applies: do not hardcode a final production WebSocket model beyond the current contract.
