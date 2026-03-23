# EIXAM Connect SDK — How to Run the Project

## Purpose of this document

This guide explains how to run the **correct EIXAM monorepo**, launch the **reference Control app**, and avoid the path and bootstrap issues that were already identified during setup.

This is written for a **shared SDK project** that will be used by multiple developers, so the goal is to make onboarding and day-to-day execution predictable.

---

## 1. Use the correct repository root

Always work from this monorepo root:

`.\eixam_connect_sdk`

This is the active repository root for the SDK project.

## 2. Monorepo structure

The current project is organized as:

- `apps/eixam_control_app` → Flutter reference app used to validate the SDK
- `packages/eixam_connect_core` → core contracts, entities, enums, domain logic
- `packages/eixam_connect_flutter` → Flutter implementations, persistence, permissions, BLE, runtime SDK logic
- `packages/eixam_connect_ui` → reusable UI layer / support widgets

This structure is intentional:
- `core` defines the SDK contract
- `flutter` implements the runtime/platform side
- `ui` provides reusable UI support
- the app under `apps/` is only a **reference/validation host app**

---

## 3. Project prerequisites

Before running the project, make sure you have:

- Flutter installed and available in PATH
- Dart installed through Flutter
- Android Studio or VS Code
- Android SDK installed
- At least one Android emulator configured
- A device visible in `flutter devices`

Recommended checks:

```bash
flutter doctor
flutter devices
```

---

## 4. Reference app and entrypoint

The current reference app is:

`apps/eixam_control_app`

The safest way to launch it is by explicitly selecting the correct entrypoint:

```bash
flutter run -t apps/eixam_control_app/lib/main.dart
```

This avoids ambiguity and makes sure the correct app entrypoint is used.

---

## 5. Recommended command sequence

From the **repository root**:

```bash
cd C:\Users\roger\flutterdev\eixam_connect_sdk
flutter clean
flutter pub get
flutter run -t apps/eixam_control_app/lib/main.dart
```

This is the recommended sequence for daily development and debugging.

## 5.1 BLE preferred device and reconnect UX

The reference app now bootstraps the SDK on app start so BLE auto-connect can run immediately.

Current behavior:
- the SDK remembers one preferred BLE device after a successful connection
- the SDK tries to reconnect on startup and when the app resumes
- unexpected foreground disconnects retry with backoff
- manual disconnect/unpair disables auto-reconnect until the next explicit connect

Current scope:
- foreground reconnect only
- no persistent background BLE daemon behavior
- reconnect uses the stored device identifier through the existing BLE scan/connect flow

---

## 6. Alternative: run from the app folder

You can also move into the app directory:

```bash
cd .\eixam_connect_sdk\apps\eixam_control_app
flutter pub get
flutter run
```

However, the preferred approach is still:

```bash
flutter run -t apps/eixam_control_app/lib/main.dart
```

because it keeps the entrypoint explicit and avoids confusion inside a monorepo.

---

## 7. How to run on Android emulator

### Option A — Android Studio
1. Open Android Studio
2. Start your Android emulator
3. From the monorepo root, run:
   ```bash
   flutter run -t apps/eixam_control_app/lib/main.dart
   ```

### Option B — terminal only
1. Start the emulator
2. Confirm it is available:
   ```bash
   flutter devices
   ```
3. Launch the app:
   ```bash
   flutter run -t apps/eixam_control_app/lib/main.dart
   ```

---

## 8. How the project currently boots

The current flow is:

1. `main.dart` opens a bootstrap screen
2. `DemoSdkFactory.create()` builds the local demo SDK
3. SDK initialization runs
4. `DemoHomePage` is shown
5. The reference app validates the SDK modules

This is useful because it makes SDK bootstrap explicit and easier to debug.

---

## 9. What the current SDK already validates

The current project already includes functional or partially functional support for:

- SOS module
- tracking module
- location / notification / Bluetooth permissions
- local notifications
- device module
- Death Man Protocol
- emergency contacts
- local persistence
- BLE skeleton
- realtime mock plumbing
- cached realtime state exposed through the SDK
- reference Flutter host app for manual validation

This means the monorepo is already acting as a real SDK project, not just a mobile app.

---

## 10. Local package dependency setup

The reference app uses local path dependencies to the packages in `../../packages/...`.

That means:
- the top-level `packages/` folder is the source of truth
- the app depends on those local packages directly
- nested duplicate repositories must not be used

A typical dependency setup looks like this:

```yaml
dependencies:
  eixam_connect_core:
    path: ../../packages/eixam_connect_core
  eixam_connect_flutter:
    path: ../../packages/eixam_connect_flutter
  eixam_connect_ui:
    path: ../../packages/eixam_connect_ui
```

---

## 11. If the app does not start

Use this checklist in order.

### 11.1 Confirm the correct repo root
You must be inside:

`.\eixam_connect_sdk`

### 11.2 Confirm the correct entrypoint
Run:

```bash
flutter run -t apps/eixam_control_app/lib/main.dart
```

### 11.3 Confirm device availability
```bash
flutter devices
```

### 11.4 Reset build artifacts
```bash
flutter clean
flutter pub get
```

### 11.5 Remove stale emulator app state
If the app still behaves strangely:
- uninstall the app from the emulator
- or wipe emulator data

---

## 12. Typical issues already observed

These are the most common problems that have already happened during setup:

- editing a `main.dart` from the wrong duplicated repo
- running the wrong repository copy
- stale local state in emulator / persistence
- assuming broadcast streams replay previous values
- mixing top-level packages with files from an old duplicate monorepo

For team work, avoiding duplicate repo copies is critical.

---

## 13. Generate APK

From the monorepo root:

```bash
flutter build apk -t apps/eixam_control_app/lib/main.dart
```

The APK will be generated under a path similar to:

```text
apps/eixam_control_app/build/app/outputs/flutter-apk/
```

---

## 14. Recommended daily workflow

For normal development:

```bash
flutter clean
flutter pub get
flutter run -t apps/eixam_control_app/lib/main.dart
```

For a safer pre-commit check:

```bash
flutter analyze
flutter test
flutter run -t apps/eixam_control_app/lib/main.dart
```

---

## 16. Recommended onboarding workflow for other developers

When a new developer joins the project, the recommended onboarding sequence is:

1. Clone the monorepo
2. Open only the top-level repo
3. Run:
   ```bash
   flutter clean
   flutter pub get
   flutter devices
   flutter run -t apps/eixam_control_app/lib/main.dart
   ```
4. Validate that the reference app boots
5. Use the reference app to test SDK modules

This ensures everybody starts from the same structure and execution flow.

---

## 17. Current documentation layout recommendation

For a shared SDK project, the documentation should be split like this:

- `README.md` → quick project entrypoint
- `RUN_PROJECT.md` → how to run the monorepo and reference app
- `SDK_ARCHITECTURE.md` → architecture and package responsibilities
- `HOST_APP_INTEGRATION.md` → how external apps integrate the SDK
- `BLE_PROVIDER_INTEGRATION.md` → BLE integration and provider design
- `NATIVE_PERMISSIONS_CHECKLIST.md` → Android/iOS permissions and native config

This file should remain focused on **execution and setup**.
