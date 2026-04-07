# Troubleshooting

## Session is set but operational flows do not work
- verify signed session values
- verify `GET /v1/sdk/me`
- verify MQTT connectivity

## SOS cancel succeeds over HTTP but state does not change
That is expected until the final lifecycle event arrives through MQTT.

## Device appears in scan but is not compatible
Compatibility should only be decided after connect plus service discovery.

## Protection Mode stays partial
- on Android, inspect readiness and owner diagnostics
- on iOS, partial coverage can be expected with the current honest base implementation
