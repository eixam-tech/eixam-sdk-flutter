# API Examples Appendix

Use the main SDK example pages for current host-app examples:

- [`../sdk/public-api-examples.md`](../sdk/public-api-examples.md)
- [`../sdk/model-reference.md`](../sdk/model-reference.md)

This appendix keeps only migration-oriented examples for compatibility methods.

## `pairDevice`

```dart
final status = await sdk.pairDevice(pairingCode: '123456');
debugPrint('device=${status.deviceId}');
```

## `unpairDevice`

```dart
await sdk.unpairDevice();
```

## `watchDeviceStatus`

```dart
final sub = sdk.watchDeviceStatus().listen((status) {
  debugPrint('lifecycle=${status.lifecycleState.name}');
});
```

## `watchSosState`

```dart
final sub = sdk.watchSosState().listen((state) {
  debugPrint('sosState=${state.name}');
});
```

## `addEmergencyContact`

```dart
final contact = await sdk.addEmergencyContact(
  name: 'Legacy contact',
  phone: '+34123456789',
  email: 'legacy@example.com',
);
debugPrint('contact=${contact.id}');
```

## `removeEmergencyContact`

```dart
await sdk.removeEmergencyContact('contact-id');
```
