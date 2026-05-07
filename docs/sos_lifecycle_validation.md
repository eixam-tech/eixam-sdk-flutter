# SOS Lifecycle Validation

This note separates automated SDK regression from real mobile validation.
Automated tests must use fakes/mocks only. Real BLE, LoRa, MQTT, staging
backend, Android lifecycle, and device firmware behavior remain manual release
validation.

## Automated Coverage

- `packages/eixam_connect_flutter/test/sdk/sos_lifecycle_matrix_test.dart`
  covers SOS-01 through SOS-16 at the SDK state/lifecycle boundary using fake
  repositories, fake device runtime events, fake rehydration, and fake LoRa
  backend-origin trigger sources.
- `packages/eixam_connect_flutter/test/sdk/eixam_connect_sdk_impl_test.dart`
  contains deeper SDK behavior tests, including stale PRE-SOS cleanup and
  backend terminal precedence on app resume.
- `eixam-app/test/sdk/application/partner_sdk_adapter_test.dart` verifies that
  idle SDK snapshots render with the intended SOS tab copy instead of generic
  `SOS disponible` text.
- `eixam-app/test/data/repositories/partner_app_repository_sos_sync_test.dart`
  now treats the repository as an SDK pass-through for SOS lifecycle snapshots;
  old app-owned preservation expectations were removed.

## Timeout/Scope Audit

| Test file | Classification | Issue | Action | Remaining risk |
| --- | --- | --- | --- | --- |
| `packages/eixam_connect_flutter/test/sdk/sos_lifecycle_matrix_test.dart` | Fast SDK regression | New focused matrix coverage | Added | Depends on current fake contracts, not live staging |
| `packages/eixam_connect_flutter/test/sdk/eixam_connect_sdk_impl_test.dart` | Valid but slow monolithic SDK suite | Full file previously exceeded a 4 minute focused run window | Kept, but matrix coverage moved to a small file | Should be split over time; do not increase timeout blindly |
| `packages/eixam_connect_flutter/test/sdk/remote_relay_sos_backend_handoff_test.dart` | Valid SDK fake-integration coverage | Exercises remote relay/backend handoff contracts with fakes | Kept | Higher scope than pure unit tests |
| `eixam-app/test/features/sos/presentation/sos_screen_test.dart` | Widget/presentation coverage | Contains legacy guard-oriented cases and is heavier than state-machine tests | Use only for rendering regressions | Not the source of SOS lifecycle truth |
| `eixam-app/test/data/repositories/partner_app_repository_sos_sync_test.dart` | Fast adapter/repository coverage | Several tests expected app-owned PRE-SOS/active preservation | Updated to SDK pass-through expectations | Remaining cases should avoid lifecycle decisions |

## Manual Real-Device Checklist

Run the existing app helper only for manual log inspection:
`..\eixam_commecial_app\eixam-app\run_live_staging.bat`

For each scenario, record: observed signal, SDK state, UI result, backend/device
alignment, and history result when terminal.

| Scenario | Manual validation focus |
| --- | --- |
| SOS-01 | No BLE app countdown, resolve during countdown, history resolved |
| SOS-02 | No BLE app active, cancel active, history cancelled |
| SOS-03 | No BLE app countdown, cancel before send, no active backend SOS |
| SOS-04 | BLE app active, app cancel, backend/device/UI aligned |
| SOS-05 | BLE app active, app resolve, backend/device/UI aligned |
| SOS-06 | BLE app active, device cancel, backend/app/UI cancelled |
| SOS-07 | BLE device countdown, device cancel during countdown |
| SOS-08 | BLE device active, app cancel |
| SOS-09 | BLE device active, app resolve |
| SOS-10 | BLE device countdown while app backgrounded, resume countdown time |
| SOS-11 | BLE device sent while app backgrounded, resume active state |
| SOS-12 | BLE device cancel before app opens, resume idle/no countdown |
| SOS-13 | LoRa trigger foreground, existing backend/realtime active signal maps |
| SOS-14 | LoRa cancel foreground, existing backend/realtime terminal clears |
| SOS-15 | LoRa trigger while app not foreground, resume active if backend exposes |
| SOS-16 | LoRa trigger/cancel before app opens, resume idle/terminal if exposed |

## Gap Rule

LoRa scenarios are only passable if existing backend/realtime/rehydration
contracts expose active and terminal state for the linked user/device. If a live
run does not show those existing signals, the SDK/app must report the gap rather
than infer success from stale local UI state.
