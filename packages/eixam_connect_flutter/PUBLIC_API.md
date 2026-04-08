# Public API

## Recommended lifecycle

1. Bootstrap the SDK with `EixamConnectSdk.bootstrap(...)`.
2. If needed, provide or update a signed session with `setSession(...)`.
3. Request permissions explicitly from the host app UX.
4. Use SDK methods and streams to drive the host app.

## Bootstrap

```dart
final sdk = await EixamConnectSdk.bootstrap(
  const EixamBootstrapConfig(
    appId: 'partner-app',
    environment: EixamEnvironment.production,
  ),
);
```

## Primary capability groups

- Session and identity
- Operational diagnostics
- Protection Mode
- Device connection and backend device registry
- SOS
- Contacts
- Permissions and notifications
- Tracking and telemetry
- Death Man
- Realtime

## Legacy note

Legacy initialization and older method names may still exist for compatibility or internal validation flows, but the recommended public path is the bootstrap flow documented above.

## Detailed references

- partner reference: `../../docs/partner/public-api.md`
- partner examples: `../../docs/partner/public-api-examples.md`
- full examples: `../../docs/full/sdk/public-api-examples.md`
