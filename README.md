# EIXAM Connect Flutter SDK

Partner-facing Flutter SDK for EIXAM's connected safety platform — SOS, device runtime, telemetry, relay ingest, notifications, and Death Man Protocol.

This monorepo is **SDK-first**: the SDK is the product. The partner app in `../eixam-app` is a host/reference integration.

## Packages

| Path | Role |
| --- | --- |
| `packages/eixam_connect_core` | Public contracts, entities, enums, state models |
| `packages/eixam_connect_flutter` | Runtime: BLE, persistence, protection, MQTT, HTTP, permissions |
| `packages/eixam_connect_ui` | Reusable UI helpers |

## Prerequisites

- Flutter on `PATH`, Android SDK, and at least one device visible in `flutter devices`
- Verify with `flutter doctor`

## Integration

```dart
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';

const notificationTexts = EixamNotificationTexts(
  protectionActiveTitle: 'Protection active',
  protectionActiveBody: 'EIXAM is monitoring your connected device.',
  protectionModeTitle: 'Protection mode',
  protectionModeBody: 'Protection mode is running in the background.',
  protectionModeChannelName: 'Protection mode',
  protectionModeChannelDescription: 'Keeps device protection active.',
  protectionSosChannelName: 'SOS alerts',
  protectionSosChannelDescription: 'Shows SOS lifecycle alerts.',
  protectionPreSosTitle: 'SOS countdown',
  protectionPreSosBody: 'An SOS alert is about to be sent.',
  protectionSosActiveTitle: 'SOS active',
  protectionSosActiveBody: 'Your SOS alert is being handled.',
  protectionSosResolvedTitle: 'SOS resolved',
  protectionSosResolvedBody: 'Your SOS alert has been resolved.',
);

final sdk = await EixamConnectSdk.bootstrap(
  const EixamBootstrapConfig(
    appId: 'partner-app',
    environment: EixamEnvironment.production,
    notificationTexts: notificationTexts,
    initialSession: EixamSession.signed(
      appId: 'partner-app',
      externalUserId: 'partner-user-123',
      userHash: 'signed-session-hash',
    ),
  ),
);
```

- `production`, `sandbox`, `staging` resolve internally; `custom` requires `EixamCustomEndpoints`.
- `initialSession` is optional; when provided its `appId` must match bootstrap `appId`.
- `notificationTexts` is required and must contain non-empty, app-localized strings.
- Bootstrap does not request permissions, pair devices, or trigger UX-sensitive actions.

## Quality checks

```bash
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test
```

Package-targeted runs are often more deterministic — see `docs/ai_context/VALIDATION_AND_TESTS.md`.

## Local development with the partner app

The partner app may use `pubspec_overrides.yaml` for workspace iteration:

```yaml
dependency_overrides:
  eixam_connect_core:
    path: ../eixam-sdk-flutter/packages/eixam_connect_core
  eixam_connect_flutter:
    path: ../eixam-sdk-flutter/packages/eixam_connect_flutter
```

## Troubleshooting

Stale state:

```bash
flutter clean && flutter pub get
```

Also uninstall the app from the emulator or device.

## Key references

- Documentation index: [docs/README.md](docs/README.md)
- Engineering contract: [AGENTS.md](AGENTS.md) (also published as [CLAUDE.md](CLAUDE.md))
- AI context index: [docs/ai_context/AI_INDEX.md](docs/ai_context/AI_INDEX.md)
- Public API surface: [packages/eixam_connect_flutter/PUBLIC_API.md](packages/eixam_connect_flutter/PUBLIC_API.md)
- SOS orchestration: [packages/eixam_connect_flutter/SOS_ORCHESTRATION.md](packages/eixam_connect_flutter/SOS_ORCHESTRATION.md)
- BLE device contract: [packages/eixam_connect_flutter/BLE_DEVICE_CONTRACT.md](packages/eixam_connect_flutter/BLE_DEVICE_CONTRACT.md)
