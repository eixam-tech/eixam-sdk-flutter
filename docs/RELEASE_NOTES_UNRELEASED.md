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

Partner release notes should describe outcomes, not storage records, private
identifiers, diagnostic markers, or internal transport details.
