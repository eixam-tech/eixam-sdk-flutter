# Host App Integration Guide

This document explains the minimum native setup required by a Flutter host app that embeds the EIXAM Connect SDK.

## Permissions overview

### Local storage
The SDK currently uses `shared_preferences` for lightweight local persistence.

- Android: no extra Manifest permission required
- iOS: no extra `Info.plist` key required

### Location
Required if the host app wants real tracking or location snapshots attached to SOS incidents.

### Notifications
Required for local notifications and later push support.

## Source of truth

For the exact native keys and platform notes, always follow:

- `packages/eixam_connect_flutter/NATIVE_PERMISSIONS_CHECKLIST.md`

## Responsibilities split

### SDK
- Requests runtime permissions through the Flutter APIs
- Exposes tracking, notifications and SOS workflows

### Host app
- Adds native Manifest and `Info.plist` entries
- Enables native capabilities when needed
- Provides product-specific UI and permission education screens


## Bluetooth host-app requirements

If the host app uses the device module for BLE pairing or device communication, it must declare the Bluetooth permissions documented in `packages/eixam_connect_flutter/NATIVE_PERMISSIONS_CHECKLIST.md`.

The SDK can request Bluetooth permission at runtime, but the native declarations remain the responsibility of the host app.
