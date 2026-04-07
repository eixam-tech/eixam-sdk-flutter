# Backend Integration

## Backend responsibilities

- signed session for the mobile user
- `GET /v1/sdk/me`
- MQTT operational flows
- `POST /v1/sdk/sos/cancel`
- contacts and device registry HTTP surfaces

## Current transport split

- SOS trigger -> MQTT
- SOS lifecycle -> MQTT events
- telemetry -> MQTT
- cancel SOS -> HTTP
