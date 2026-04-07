# SDK Overview

EIXAM Connect is the embeddable SDK/API layer of EIXAM.

It is designed for host apps that need to integrate:
- signed session bootstrap
- SOS flows
- telemetry publish
- emergency contacts
- backend device registry
- local BLE/runtime device state
- permissions and notifications
- Protection Mode as an additive resilience capability

## Product rules

- the SDK is the core product layer
- the host app should remain thin
- the reference control app is a validation host, not the final product UX
- business-critical logic should live in the SDK rather than widgets
