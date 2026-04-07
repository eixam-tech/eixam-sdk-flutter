# Flutter Integration

Flutter is the recommended option when your product already has a Flutter host app and you want EIXAM to provide the SOS and device logic layer.

## What the Flutter app owns

Your Flutter app should remain a thin UI layer over the SDK. It should own:

- application navigation
- screen composition and branding
- user input and UI validation
- calling the public SDK facade
- rendering SDK state from streams and snapshots

## What the SDK owns

The SDK should own the EIXAM service behavior, including:

- session bootstrap and identity enrichment
- SOS lifecycle
- device lifecycle and command flows
- telemetry/tracking publication
- permissions orchestration
- protection mode runtime state and diagnostics

## Install the plugin

Add the package using the version or distribution channel provided by EIXAM:

```yaml
dependencies:
  eixam_connect_flutter: <version-provided-by-eixam>
```

Do not use local monorepo `path:` dependencies in a partner app.

## Typical integration flow

1. Create the SDK with the EIXAM environment URLs.
2. Provide the signed `EixamSession` from your backend/auth flow.
3. Subscribe to SDK streams such as SOS state, device state, and diagnostics.
4. Build your own screens on top of the public SDK methods.
5. Use the official examples as references for UI wiring and interaction patterns.

## Implementation guidance

- import only `package:eixam_connect_flutter/eixam_connect_flutter.dart`
- keep business and device orchestration in the SDK layer
- avoid importing internal `src/...` classes
- treat the host app as presentation and workflow glue around the SDK

## Recommended follow-up

- [Quickstart](./quickstart.md)
- [Public API](./public-api.md)
- [API Examples](./public-api-examples.md)
- [Permissions Checklist](./permissions-checklist.md)
