# EIXAM Connect SDK — How to Run the Project

## Purpose

This guide explains how to run the monorepo, launch the validation app, and keep a clean distinction between the **public partner bootstrap flow** and the **internal validation app bootstrap flow**.

## Repository root

Always work from the monorepo root:

```text
C:\Users\roger\flutterdev\eixam_connect_sdk
```

Do not work from duplicated nested copies.

## Monorepo structure

- `apps/eixam_control_app` → Flutter validation host app
- `packages/eixam_connect_core` → SDK contracts, entities, enums, domain models
- `packages/eixam_connect_flutter` → Flutter runtime implementation, BLE, persistence, permissions, protection, MQTT
- `packages/eixam_connect_ui` → reusable UI helpers

## Public partner flow vs validation app flow

### Public partner flow

Partner documentation should always present:

```dart
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

### Internal validation app flow

The validation app may still use internal factory/bootstrap composition to support environment switching, diagnostics and local debug defaults. That internal flow is not the recommended partner integration path.

## Prerequisites

- Flutter installed and available in `PATH`
- Dart available through Flutter
- Android SDK installed
- Android Studio or VS Code
- at least one emulator or physical device visible in `flutter devices`

Recommended checks:

```bash
flutter doctor
flutter devices
```

## Recommended command sequence

From the repository root:

```bash
flutter clean
flutter pub get
flutter run -t apps/eixam_control_app/lib/main.dart
```

## Running the validation app

### Android Studio

1. Start an emulator or connect a device.
2. From the repository root run:

```bash
flutter run -t apps/eixam_control_app/lib/main.dart
```

### Terminal-only workflow

```bash
flutter devices
flutter run -t apps/eixam_control_app/lib/main.dart
```

## Validation app behavior

The validation app bootstraps an SDK instance, loads saved backend config, and then shows thin UI surfaces that consume SDK diagnostics, device state, protection state and SOS lifecycle.

## Local package dependency model

The reference app uses local path dependencies pointing to `../../packages/...`.

Example:

```yaml
dependencies:
  eixam_connect_core:
    path: ../../packages/eixam_connect_core
  eixam_connect_flutter:
    path: ../../packages/eixam_connect_flutter
  eixam_connect_ui:
    path: ../../packages/eixam_connect_ui
```

## Troubleshooting

### Wrong repo copy

If changes are not reflected, confirm you are running the top-level monorepo and not an older duplicate copy.

### Stale state

If the app behaves inconsistently:

```bash
flutter clean
flutter pub get
```

Also consider uninstalling the app from the emulator/device.

### Wrong entrypoint

Always prefer:

```bash
flutter run -t apps/eixam_control_app/lib/main.dart
```

## Quality checks

Before merging meaningful changes:

```bash
dart format --set-exit-if-changed .
flutter analyze --no-fatal-infos
flutter test
```
