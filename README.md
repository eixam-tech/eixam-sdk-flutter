# EIXAM Connect Flutter SDK

EIXAM Connect is the partner-facing integration layer of EIXAM's connected safety platform.

This monorepo is **SDK-first**: the SDK is the product, the validation app is a thin host to exercise it.

## Repository structure

| Path | Role |
|------|------|
| `apps/eixam_control_app` | Validation host app — exercises SDK flows, not a partner UX |
| `packages/eixam_connect_core` | Public contracts, entities, enums, state models |
| `packages/eixam_connect_flutter` | Runtime implementation — BLE, persistence, protection, MQTT, permissions |
| `packages/eixam_connect_ui` | Reusable UI helpers |

## Prerequisites

- Flutter installed and available in `PATH`
- Android SDK installed (Android Studio or VS Code)
- At least one emulator or physical device visible in `flutter devices`

```bash
flutter doctor
flutter devices
```

## Running the validation app

From the **repository root**:

```bash
flutter clean
flutter pub get
flutter run -t apps/eixam_control_app/lib/main.dart
```

> Always run from the monorepo root. Do not work from nested copies.

## Partner integration

Bootstrap the SDK with a single call:

```dart
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';

final sdk = await EixamConnectSdk.bootstrap(
  const EixamBootstrapConfig(
    appId: 'partner-app',
    environment: EixamEnvironment.production,
    initialSession: EixamSession.signed(
      appId: 'partner-app',
      externalUserId: 'partner-user-123',
      userHash: 'signed-session-hash',
    ),
  ),
);
```

- `production`, `sandbox`, and `staging` are resolved internally
- `custom` requires `EixamCustomEndpoints`
- `initialSession` is optional; when provided its `appId` must match bootstrap `appId`
- Bootstrap does not request permissions, pair devices, or trigger UX-sensitive actions

## Local package dependency model

The validation app uses local path dependencies:

```yaml
dependencies:
  eixam_connect_core:
    path: ../../packages/eixam_connect_core
  eixam_connect_flutter:
    path: ../../packages/eixam_connect_flutter
  eixam_connect_ui:
    path: ../../packages/eixam_connect_ui
```

## Quality checks

Before merging:

```bash
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test
```

## Troubleshooting

**Stale state** — if the app behaves inconsistently:

```bash
flutter clean
flutter pub get
```

Also uninstall the app from the emulator or device.

**Wrong entrypoint** — always use:

```bash
flutter run -t apps/eixam_control_app/lib/main.dart
```

## Key references

- Engineering contract: [`AGENTS.md`](AGENTS.md)
- Package API: [`packages/eixam_connect_flutter/README.md`](packages/eixam_connect_flutter/README.md)
- Public API surface: [`packages/eixam_connect_flutter/PUBLIC_API.md`](packages/eixam_connect_flutter/PUBLIC_API.md)
- SOS orchestration: [`packages/eixam_connect_flutter/SOS_ORCHESTRATION.md`](packages/eixam_connect_flutter/SOS_ORCHESTRATION.md)
- BLE device contract: [`packages/eixam_connect_flutter/BLE_DEVICE_CONTRACT.md`](packages/eixam_connect_flutter/BLE_DEVICE_CONTRACT.md)
- Native permissions: [`packages/eixam_connect_flutter/NATIVE_PERMISSIONS_CHECKLIST.md`](packages/eixam_connect_flutter/NATIVE_PERMISSIONS_CHECKLIST.md)
- Migration guide: [`packages/eixam_connect_flutter/MIGRATION.md`](packages/eixam_connect_flutter/MIGRATION.md)
