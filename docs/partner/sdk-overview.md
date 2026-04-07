# SDK Overview

EIXAM Connect is the embeddable integration layer for companies that want to use EIXAM as their SOS and connected safety service.

It is designed for partner products that need:
- signed session bootstrap
- SOS flows
- telemetry publish
- emergency contacts
- backend device registry
- local BLE/runtime device state
- permissions and notifications
- Protection Mode as an additive resilience capability

## How partners typically start

1. Register the app with EIXAM.
2. Receive environment details, credentials, and the session/auth contract.
3. Choose the integration surface that fits the product:
   - Flutter
   - Android
   - iOS
   - Web
   - API / backend
4. Install the SDK or connect to the API.
5. Implement your product UI on top of the official examples and public API.

## Integration model

- the SDK is the service logic layer
- the host app should remain thin
- the host app should focus on UI, branding, navigation, and product-specific workflows
- business-critical EIXAM behavior should come from the SDK rather than custom widget logic
