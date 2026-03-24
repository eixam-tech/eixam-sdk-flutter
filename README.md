## Architecture principles

EIXAM is being built as an **SDK-first safety platform** in Flutter/Dart.

This means:

- the SDK is the core product layer
- the host app must remain thin
- the reference/control app is a validation host, not the final product UX
- critical logic should live in the SDK, not in app widgets

The current validated architecture is:

- **EIXAM SOS Core**
- **EIXAM Connect SDK**
- **EIXAM Control App** (reference/demo host)
- **Safety Dashboard** (future operational layer)

## Key project documentation

Start here for architecture and project-level guidance:

- `docs/sdk/SDK_ARCHITECTURE.md`
- `docs/sdk/SDK_DECISIONS.md`
- `docs/sdk/SDK_QUALITY_GATES.md`
- `docs/sdk/SDK_TESTING_STRATEGY.md`

APP/BLE integration source-of-truth docs:

- `docs/app_ble/APP_HANDOFF_FINAL.md`
- `docs/app_ble/BLE_APP_PROTOCOL.md`
- `docs/app_ble/BLE_BACKLOG_SYNC_PROTOCOL.md`
- `docs/app_ble/GUIDED_RESCUE_PHASE1.md`

Additional project context:

- `docs/context/TEAM_HANDOFF_INDEX.md`
- `docs/context/ROADMAP.md`

## Reference app scope

`apps/eixam_control_app` is the current reference host app used to:

- bootstrap the SDK
- validate SDK module integration
- test technical integration flows
- support internal operational validation

It is not the final product UX. It is primarily a validation host and technical playground.

## Developer quality checks

Before merging relevant changes, run:

- `dart format --set-exit-if-changed .`
- `flutter analyze`
- `flutter test`

For architecture and quality expectations, see:

- `docs/sdk/SDK_DECISIONS.md`
- `docs/sdk/SDK_QUALITY_GATES.md`
- `docs/sdk/SDK_TESTING_STRATEGY.md`