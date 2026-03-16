# EIXAM Connect SDK · Native permissions checklist

This file is a quick reference for any host app that integrates the SDK.

## Important note about local persistence

The SDK currently uses `shared_preferences` for lightweight local persistence.

- `shared_preferences` **does not require any extra Android Manifest permission**.
- `shared_preferences` **does not require any extra iOS `Info.plist` key**.
- Data is stored inside the app sandbox managed by Android/iOS.

## Android · `android/app/src/main/AndroidManifest.xml`

Minimum permissions for the current SDK capabilities:

```xml
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

<!-- Bluetooth / BLE -->
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
```

If you later enable background tracking:

```xml
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />
```

### Android notes

- `POST_NOTIFICATIONS` is required on Android 13+ for local and push notifications.
- For Android 12+ BLE flows, the host app should declare `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT`.
- Legacy `BLUETOOTH` and `BLUETOOTH_ADMIN` are still useful for compatibility with Android 11 and earlier.
- `flutter_local_notifications` does **not** require a storage permission.
- `shared_preferences` does **not** require a storage permission.
- Keep a valid notification icon configured for Android (for example `@mipmap/ic_launcher` or a dedicated monochrome notification icon).
- If the host app uses custom notification channels, review the channel configuration together with the SDK defaults.
- If BLE scanning should never be used to infer physical location, review whether you want to mark `BLUETOOTH_SCAN` with `usesPermissionFlags="neverForLocation"` in the host app.

## iOS · `ios/Runner/Info.plist`

Minimum keys for the current SDK capabilities:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>EIXAM needs your location to power tracking and SOS position snapshots.</string>

<key>NSBluetoothAlwaysUsageDescription</key>
<string>EIXAM needs Bluetooth access to pair and communicate with the safety device.</string>
```

If you later enable background tracking:

```xml
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>EIXAM may need location in background for continuous safety tracking.</string>
<key>UIBackgroundModes</key>
<array>
  <string>location</string>
</array>
```

If you later enable BLE communication in background:

```xml
<key>UIBackgroundModes</key>
<array>
  <string>bluetooth-central</string>
</array>
```

### iOS notes

- Local and push notification permission is requested at runtime; there is no extra `Info.plist` usage-description key required for the current notification flow.
- `shared_preferences` does **not** require any extra iOS permission.
- If the host app later uses remote push notifications, Apple Push Notification capabilities must be enabled in Xcode.
- If the host app later needs background execution for long-running tracking or BLE flows, background modes must be reviewed carefully.
- The SDK can request Bluetooth permission at runtime, but the host app must still provide the Bluetooth usage description shown above.

## Runtime responsibilities

The SDK already handles runtime permission requests for:

- location permission
- notification permission
- Bluetooth permission

The host app is still responsible for:

- declaring the native permissions shown above
- configuring Android/iOS project capabilities correctly
- validating notification icon/channel configuration
- reviewing background tracking implications before enabling them
- reviewing BLE background implications before enabling them

## Local persistence (`shared_preferences`)

The current SDK persistence layer uses `shared_preferences`.

- Android: no extra permission required in `AndroidManifest.xml`
- iOS: no extra key required in `Info.plist`
