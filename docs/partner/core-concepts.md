# Core Concepts

## Signed session vs canonical identity

The host app supplies the signed session and the SDK enriches identity through `GET /v1/sdk/me`.

## Thin host app

The host app should consume SDK methods and streams. It should not own BLE protocol parsing, MQTT topic building, or device orchestration.

## Backend registry vs local runtime

Do not mix backend device registry with the local BLE/runtime device surface.

## Current transport split

- SOS trigger -> MQTT
- SOS lifecycle updates -> MQTT
- telemetry publish -> MQTT
- cancel SOS -> HTTP
