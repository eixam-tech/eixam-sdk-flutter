# Unreleased SDK summary

No semantic version is assigned by this document.

- Added an authoritative, account-scoped persisted SOS lifecycle with typed
  activation, cancellation, recovery, and failure outcomes.
- Added independent app/backend, connected-device, physical-device observation,
  and restored-active capability paths; app-only activation does not require a
  registered or connected device, BLE, tracking, or a location fix.
- Added monotonic lifecycle/capability revisions for consistent host merges and
  stale-snapshot rejection.
- Added SDK-owned generation-scoped countdown cancellation on both sides of the
  dispatch boundary.
- Added bounded already-active recovery without arbitrary history promotion.
- Added backend cancellation without BLE where supported, while retaining
  provenance through pending or failed cancellation.
- Added connected-device mirrored pre-SOS handoff so authoritative active state
  replaces countdown immediately and later incident identity enriches the same
  generation.
- Added SDK-owned SOS phone-location acquisition on Android and iOS. SOS
  context teardown preserves independent Profile sharing and DMP contexts.
- Added provisional-to-canonical incident correlation and versioned backend /
  emergency-contact progress for multiple subscribers.
- Classified connected-device terminal cancellation locally so a confirmed
  terminal boundary can rearm immediately without treating it as remote relay
  residue.
- Hardened release diagnostics to presence/category fields, with debug-only
  opt-in device/location traces disabled by default.
- Moved the iOS global Core Location service-status query off the main queue
  and use cached delegate/application state during sample delivery.

Validation checkpoint: 665 SDK tests passed at
`edbfd2328f759ee94908d8d72c201a26cd69670e`. The listed physical and backend
flows were validated against staging. Production deployment and store release
remain separate, unvalidated gates.

Partner release notes should describe outcomes, not storage records, private
identifiers, diagnostic markers, or internal transport details.
