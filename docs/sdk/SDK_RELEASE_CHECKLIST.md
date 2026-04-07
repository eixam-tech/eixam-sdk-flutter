# SDK Release Checklist

Use this checklist before publishing a new SDK release.

## Release Gates

### 1. Public API Review

- confirm the supported public surface is limited to the intended package entrypoints
- verify root exports still match the documented public API boundary
- confirm no internal repositories, adapters, controllers, protocol helpers, or storage/runtime internals are exposed unintentionally

### 2. Analyze / Test Status

- run `flutter analyze --no-fatal-infos`
- run the relevant package and app test suites
- confirm no release-blocking failures remain

### 3. Example App Validation

- verify the example app still builds
- verify the example app still demonstrates the intended partner journey
- confirm the example uses only supported public API

### 4. Changelog Update

- add a release entry to the package changelog
- summarize public API changes, fixes, and notable partner-facing behavior changes

### 5. Migration Notes Update

- update migration notes if any public API changed
- call out renamed, removed, or no-longer-exported symbols

### 6. Tag Naming Convention

- use a consistent SDK tag format such as `eixam_connect_flutter-v0.2.0`
- ensure the tag matches the package version being released

### 7. Partner Docs Review

- review partner docs for installation accuracy
- confirm quickstart, public API, and example references are current
- remove any monorepo-only or internal-team wording

### 8. Backend / Auth / Session Compatibility Check

- confirm the release still matches the current backend and auth contract
- verify `appId`, environment URLs, signed session handling, and identity/session enrichment behavior remain aligned

### 9. Android and iOS Smoke Test

- run a basic host-app smoke test on Android
- run a basic host-app smoke test on iOS
- validate at least SDK creation, session setup, permissions, and one core flow such as device connect or SOS

### 10. Partner Release Communication

- prepare short release notes for partners
- call out new capabilities, behavior changes, migration requirements, and known limitations
- include links to docs, changelog, migration notes, and support channels
