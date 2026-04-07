# API Reference

## Bootstrap

```dart
final sdk = await ApiSdkFactory.createHttpApi(
  apiBaseUrl: 'https://api.example.com',
  websocketUrl: 'wss://mqtt.example.com/mqtt',
);
```

## Endpoints currently referenced by docs

- `GET /v1/sdk/me`
- `GET /v1/sdk/sos`
- `POST /v1/sdk/sos/cancel`
- `/v1/sdk/devices`
