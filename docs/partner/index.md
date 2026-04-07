# EIXAM Connect SDK - Partner Documentation

EIXAM Connect is the partner integration layer for companies that want to add EIXAM-powered SOS, device, telemetry, and operational flows to their own product.

This documentation is organized around the real onboarding journey for an external customer.

## Recommended reading order

1. [SDK Overview](./sdk-overview.md)
   Understand what EIXAM provides and how the SDK fits into your product.
2. [Quickstart](./quickstart.md)
   Start with the information your company receives from EIXAM, create the SDK, and provide the signed session.
3. Choose your integration surface:
   - [Flutter Integration](./flutter-integration.md)
   - [Android Host Integration](./android-integration.md)
   - [iOS Host Integration](./ios-integration.md)
   - [Backend Integration](./backend-integration.md)
   - [API Reference](./api-reference.md)
4. [Public API](./public-api.md)
   Review the official Dart-facing SDK contract.
5. [API Examples](./public-api-examples.md)
   Use the official examples to implement your own UI and user flows.
6. [Core Concepts](./core-concepts.md)
   Understand session, device, protection, and runtime responsibilities.
7. Supporting references as needed:
   - [Permissions Checklist](./permissions-checklist.md)
   - [Protection Mode](./protection-mode.md)
   - [Troubleshooting](./troubleshooting.md)

## Partner journey

The intended journey is:

1. Your company decides to use EIXAM as its SOS service layer.
2. Your company registers its app with EIXAM.
3. EIXAM provides your credentials, environment URLs, session/auth contract, and any enabled capabilities.
4. Your team chooses the right SDK surface: Flutter, Android, iOS, Web, or direct API/backend integration.
5. Your team opens the corresponding SDK docs.
6. Your engineers install the SDK or plugin in the host application.
7. Your product team implements its own UI using the official public API and examples.
