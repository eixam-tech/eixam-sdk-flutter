# Notifications

## Main Sources

- Local notifications adapter: `packages/eixam_connect_flutter/lib/src/data/repositories/local_notifications_repository.dart`
- SOS notification ownership: `packages/eixam_connect_flutter/lib/src/sdk/eixam_connect_sdk_impl.dart`
- Android protection background notifications:
  - `packages/eixam_connect_flutter/android/src/main/kotlin/dev/eixam/connect/flutter/protection/ProtectionForegroundService.kt`

## Local App Notifications

- SDK owns local notification initialization and action dispatch.
- `LocalNotificationsRepository` creates:
  - `eixam_local_alerts`
  - `eixam_sos_alerts`
- iOS/macOS categories include actions for:
  - `open_app`
  - `cancel_sos`
  - `confirm_sos`
  - `resolve_sos`
  - `confirm_dead_man_safe`

## SOS Notifications

- Emitted only for device-origin notifiable states:
  - `preConfirm`
  - `active`
  - `acknowledged`
- SDK suppresses duplicate notifications per SOS cycle/state.
- On cycle close (`inactive` or `resolved`), SDK clears related SOS notifications.
- Notification actions may:
  - open the app
  - attempt BLE command execution immediately if command path is available
  - fall back to queued navigation if BLE command cannot run in background

## Pre-SOS Notifications

- Public/device PRE-SOS is notified with title `Preventive SOS sent`.
- Body indicates pending confirmation and asks the user to open the app.

## DMP Notifications

- DMP uses local notifications for:
  - overdue warning
  - awaiting confirmation
  - escalation notice
- `I'm OK` action is supported for DMP notifications.

## Background Behavior

- Android protection mode has its own foreground-service notification channel and SOS event notifications.
- Protection mode can emit native-background notifications such as:
  - pre-alert
  - active SOS
  - resolved SOS
- BLE notification actions in the Flutter SDK may be deferred into queued navigation if connection/command readiness is missing.

## Foreground Suppression Rules

- There is explicit per-cycle SOS duplicate suppression in `EixamConnectSdkImpl`.
- There is no broad repository-level “do not show notifications while app is foregrounded” rule in `LocalNotificationsRepository`.
- `Needs verification`: if product wants foreground suppression beyond cycle deduplication, that rule is not currently encoded as a general repository policy.

## Main Files

- `packages/eixam_connect_flutter/lib/src/data/repositories/local_notifications_repository.dart`
- `packages/eixam_connect_flutter/lib/src/sdk/eixam_connect_sdk_impl.dart`
- `packages/eixam_connect_core/lib/src/interfaces/notifications_repository.dart`
- `packages/eixam_connect_core/lib/src/entities/ble_notification_navigation_request.dart`
- `packages/eixam_connect_flutter/android/src/main/kotlin/dev/eixam/connect/flutter/protection/ProtectionForegroundService.kt`

## Related Tests

- `packages/eixam_connect_flutter/test/sdk/eixam_connect_sdk_impl_test.dart`
- `apps/eixam_control_app/test/validation_console_controller_test.dart`
- `packages/eixam_connect_flutter/test/sdk/android_protection_platform_adapter_test.dart`
- `packages/eixam_connect_flutter/test/sdk/ios_protection_platform_adapter_test.dart`

## Needs Verification

- Native iOS background notification nuances for protection mode are only partially implied by the Swift bridge and current diagnostics text. Preserve current implementation and avoid adding claims beyond the existing code/tests.
