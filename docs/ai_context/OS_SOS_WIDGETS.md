# OS SOS Widgets

This plan covers native Android and iOS OS-level SOS widgets only. Widgets are
entry points into the existing app/SDK SOS path; they must not implement
emergency routing, raw BLE logic, backend routing, or generic app shortcuts.

## Shared SDK Contract

Public contract:

- `packages/eixam_connect_core/lib/src/entities/os_sos_widget_activation.dart`
- `packages/eixam_connect_core/lib/src/entities/sos_trigger_payload.dart`
- `packages/eixam_connect_core/lib/src/interfaces/eixam_connect_sdk.dart`

Native/widget taps should enter Flutter with an `OsSosWidgetActivation`:

- `source`: always `os_widget`
- `platform`: `android` or `ios`
- `actionId`: stable id for the widget action attempt
- `nonce`: unique fallback id for the specific tap/intent
- `timestamp`: UTC time the native layer created the action
- `confirmationMode`: `countdown`, `hold`, or `app_opened`

The SDK handles this through `EixamConnectSdk.handleOsSosWidgetActivation(...)`.
It checks current SOS/pre-SOS state, dedupes recent action ids, and routes into
the existing `startPreSos`, `confirmPreSos`, or `triggerSos` path. Countdown
sessions persist their activation payload so expiry still activates with
`triggerSource=os_widget`.

## Android Implementation Points

SDK/plugin foundation:

- `packages/eixam_connect_flutter/android/src/main/AndroidManifest.xml`:
  merge a widget receiver only if the widget is shipped by the SDK package.
- `packages/eixam_connect_flutter/android/src/main/kotlin/dev/eixam/connect/flutter/...`:
  add a small native widget contract/intent builder if the SDK owns the
  Android receiver.

Host app implementation:

- `android/app/src/main/AndroidManifest.xml`:
  register the `AppWidgetProvider` receiver and any app-open intent filters.
- `android/app/src/main/kotlin/<app package>/soswidget/EixamSosWidgetProvider.kt`:
  render the 1x1/2x1 RemoteViews and create guarded PendingIntents.
- `android/app/src/main/res/xml/eixam_sos_widget_info.xml`:
  declare min dimensions, resize mode, update period, and preview metadata.
- `android/app/src/main/res/layout/eixam_sos_widget.xml`:
  prominent SOS button plus compact state labels.
- `android/app/src/main/res/drawable/...`:
  SOS button and status backgrounds.
- `android/app/src/main/kotlin/<app package>/MainActivity.kt`:
  forward widget intents into Flutter with the shared activation payload.

For the current local partner app path, these map to:

- `c:\Users\roger\flutterdev\eixam_app\android\app\src\main\AndroidManifest.xml`
- `c:\Users\roger\flutterdev\eixam_app\android\app\src\main\kotlin\com\example\eixam_app\MainActivity.kt`

Default Android tap behavior should be: if SOS is active, open the active SOS
screen; otherwise open a dedicated confirmation flow or start a short SDK
pre-SOS countdown. Do not use a one-tap immediate SOS PendingIntent by default.

## iOS Implementation Points

Host app implementation:

- `ios/Runner.xcodeproj` / `ios/Runner.xcworkspace`:
  add a Widget Extension target.
- `ios/EixamSosWidget/EixamSosWidget.swift`:
  WidgetKit timeline and compact state rendering.
- `ios/EixamSosWidget/EixamSosControl.swift`:
  Control Widget / Lock Screen / Control Center action where available.
- `ios/EixamSosWidget/EixamSosIntent.swift`:
  AppIntent that either opens the app to confirmation or reports a completed
  guarded hold/countdown action.
- `ios/Runner/AppDelegate.swift` and `ios/Runner/Info.plist`:
  handle the app-open URL/user activity and hand the activation to Flutter.
- App Group entitlements:
  share only a lightweight derived SOS/device/protection snapshot.

For the current local partner app path, these map to:

- `c:\Users\roger\flutterdev\eixam_app\ios\Runner\AppDelegate.swift`
- `c:\Users\roger\flutterdev\eixam_app\ios\Runner\Info.plist`
- new `c:\Users\roger\flutterdev\eixam_app\ios\EixamSosWidget\...` files

iOS widgets cannot be treated as a reliable long-running SOS runtime. Prefer
opening the app to the SOS confirmation flow unless the action surface supports
a reliable guarded AppIntent.

## State Snapshot

Native widgets may read a lightweight derived snapshot:

- protected/protection active
- device connected
- SOS active
- pre-SOS countdown active

The snapshot is display-only. The SDK/app state remains the source of truth.

## False Positive Rules

- No default one-tap immediate SOS.
- Use countdown, hold, or app-open confirmation.
- Debounce native taps before forwarding.
- Include `actionId` and `nonce`.
- Treat repeated action ids as duplicates.
- If SOS is already active, open active SOS instead of creating another SOS.
- Do not dial 112/emergency services directly from the widget.
