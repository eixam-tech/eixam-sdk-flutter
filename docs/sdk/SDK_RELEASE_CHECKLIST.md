# SDK Release Checklist

Use this checklist before freezing a partner-ready SDK release such as `v0.3.0`.

## Release Gates

### 1. Version and Tag Ready

- confirm the package version is final
- confirm the release tag is final and matches the version being shipped
- confirm the release artifact set is the one intended for partners

### 2. Public API Ready

- confirm the supported public surface is limited to the intended package entrypoints
- verify root exports still match the documented public API boundary
- confirm no internal repositories, adapters, controllers, protocol helpers, or storage/runtime internals are exposed unintentionally

### 3. Analyze and Test Status

- run `flutter analyze --no-fatal-infos`
- run the relevant package and app test suites
- confirm no release-blocking failures remain

### 4. Example App Ready

- verify the example app still builds
- verify the example app still demonstrates the intended partner journey
- confirm the example uses only supported public API

### 5. Docs Ready

- review `docs/partner/`
- review `docs/full/`
- confirm `docs/partner/quickstart.md` is current
- confirm the canonical git dependency snippet is current
- confirm the public bootstrap example is current
- confirm onboarding and integration notes are ready for release

### 6. Site Artifacts Ready

- confirm `site/partner/` has been generated for the release
- confirm `site/full/` has been generated for the release
- confirm the generated sites match the reviewed docs set

### 7. Release Notes Ready

- update the package changelog
- update migration notes if the public SDK surface changed
- prepare the partner-facing release communication notes

### 8. Backend and Session Compatibility Ready

- confirm the release still matches the current backend and auth contract
- verify `appId`, environment URLs, signed session handling, and identity/session enrichment behavior remain aligned

### 9. Android and iOS Smoke Test Ready

- run a basic host-app smoke test on Android
- run a basic host-app smoke test on iOS
- validate at least SDK bootstrap, session setup, permissions, and one core flow such as device connect or SOS
