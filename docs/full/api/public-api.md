# API Surface Appendix

Use the main SDK docs for the current practical reference:

- [`../sdk/public-api.md`](../sdk/public-api.md)
- [`../sdk/public-api-examples.md`](../sdk/public-api-examples.md)
- [`../sdk/model-reference.md`](../sdk/model-reference.md)

This appendix keeps the compatibility and migration-only public surfaces out of the main partner path while still documenting them for internal teams.

## Legacy / compatibility methods

- `initialize(EixamSdkConfig config)`
- `pairDevice({required String pairingCode})`
- `unpairDevice()`
- `watchDeviceStatus()`
- `watchSosState()`
- `addEmergencyContact(...)`
- `removeEmergencyContact(String contactId)`

## Notes

- New partner integrations should use the methods documented under `docs/full/sdk/`.
- Return-type guidance for the current SDK flow lives in the SDK model reference page, not in this appendix.
