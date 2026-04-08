# EIXAM Connect Flutter

Flutter runtime implementation of the EIXAM Connect SDK.

This package is the partner-facing Flutter integration surface for EIXAM's connected safety platform.

## Recommended public entrypoint

Use the single-call bootstrap flow:

```dart
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';

final sdk = await EixamConnectSdk.bootstrap(
  const EixamBootstrapConfig(
    appId: 'partner-app',
    environment: EixamEnvironment.sandbox,
    initialSession: EixamSession.signed(
      appId: 'partner-app',
      externalUserId: 'partner-user-123',
      userHash: 'signed-session-hash',
    ),
  ),
);
```

## Bootstrap behavior

- `production`, `sandbox`, and `staging` are resolved internally
- `custom` requires `EixamCustomEndpoints`
- `initialSession` is optional
- when provided, `initialSession.appId` must match the bootstrap `appId`
- bootstrap preserves session lifecycle and clears mismatched restored sessions
- bootstrap does not request permissions, pair devices, or trigger other UX-sensitive actions

## Where to read next

- `PUBLIC_API.md`
- `MIGRATION.md`
- `../../docs/partner/quickstart.md`
- `../../docs/partner/public-api-examples.md`
