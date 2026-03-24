# SDK Testability Notes

This note captures the main SDK design seams that currently make automated testing harder than it should be.

## Main gaps

- Time is still implicit in several runtime paths through `DateTime.now()`.
  - Affected areas: SOS incident creation, Death Man monitoring, contacts/device ID creation, device lifecycle timestamps.
  - Impact: behavior is harder to assert deterministically and time-based transitions are awkward to cover.

- Timer orchestration is embedded directly in SDK implementations.
  - Affected areas: `EixamConnectSdkImpl` Death Man monitoring, `InMemoryDeviceRepository` heartbeat refresh, BLE reconnect scheduling.
  - Impact: transition-heavy behavior requires integration-style tests instead of tight unit tests.

- ID generation is inline and not injectable.
  - Affected areas: `InMemorySosRepository`, `InMemoryDeathManRepository`, `InMemoryContactsRepository`.
  - Impact: tests can assert shape and state, but not exact outputs cleanly.

- Platform permission logic is tightly coupled to static platform APIs.
  - Affected area: `PlatformPermissionsRepository`.
  - Impact: orchestration is best tested only above the repository layer unless adapter seams are introduced.

- Some SDK-facing controllers depend on raw SDK entities that are still slightly too low-level.
  - Affected areas: rescue and realtime presentation layers.
  - Impact: host consumers still need to derive display logic that should gradually move into SDK-facing view-state adapters.

## APIs that are still too raw for consumers

- Realtime types are public concepts but are not consistently exported through the main core barrel.
- Guided Rescue Phase 1 still has no public SDK contract for:
  - request position
  - SOS acknowledge
  - buzzer on/off
  - rescue status request
- Tracking exposes current state and positions, but there is no explicit SDK model for stale/healthy tracking summary.

## Recommended refactors before Guided Rescue Phase 1 expands

- Introduce small injectable seams for `Clock`, `IdGenerator`, and timer/scheduler behavior in the runtime layer.
- Add dedicated Rescue SDK contracts and a presentation-ready `RescueViewState`.
- Export realtime types cleanly from `eixam_connect_core` so SDK-facing layers do not need internal imports.
- Add a richer tracking summary contract so stale logic is owned by the SDK-facing layer instead of repeated in consumers.
