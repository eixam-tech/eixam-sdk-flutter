# Android factory TAG activation

This flow uses the SDK's migration, firmware-update and provisioning authorities.
The host presents their typed results. iOS inspection, repair and provisioning
semantics are unchanged.

## Inspection request freshness

Stock nRF52 firmware remembers the last `ToRadio` bytes and rejects an identical
consecutive write. That buffer resets on a physical GAP disconnect. Releasing
one Android GATT client does not establish that the physical link was released.
Immediate QR inspection, acquisition inspection and migration revalidation can
therefore receive no metadata even though Android reports a successful write.

Each Android inspection now allocates a fresh nonzero uint32 config request ID,
excluding the special config-only and node-only IDs `69420` and `69421`. This
uses the existing read-only PhoneAPI request and changes no protocol contract.
The existing iOS allocator and completion/security policies remain unchanged.
The Android request ID is included in sanitized inspection-stage diagnostics.

The stock 2.7.26 PhoneAPI sends my-info, UI data, own-node info and metadata before
the rest of configuration. Ordinary nonces preserve that prefix; the config-only
special nonce changes a later transition to skip other nodes. Inspection does
not need to consume the rest of the node database. QR verification still requires
the selected peripheral's authoritative manufacturing MAC and hardware model;
an advertisement suffix alone cannot authorize migration.

The Android statements in the earlier [iOS inspection report](IOS_STOCK_INSPECTION.md)
describe its October 28 checkpoint. This Android correction supersedes that
checkpoint's constant-request-byte behavior.

## Android inspection ownership

A failed bond can leave a passive runtime metadata read in service discovery.
Previously its transient-disconnect retry could reopen Android GATT after the
inspection cleanup, outside the normal reconnect authority. The resulting App
connection also prevented a new stock advertisement from appearing.

Android runtime refresh now rejects reads while ownership is suspended and
fences each awaited stage with an ownership revision. Passive Android service
discovery never reconnects; explicit connection recovery remains responsible
for acquisition. Once explicit candidate inspection has exclusive priority and
runtime ownership is released, it also awaits disconnection of any selected App
GATT link not tracked by the runtime. It does not disconnect a system-only link
or another peripheral.

Discovery can expose an Android system-connected stock-looking peripheral as
an unverified inspection candidate. Android's native connected-device API does
not filter by service UUID, so this path accepts only the strict stock name
shape and excludes a known cached Eixam service tree. It supplies no canonical
hardware MAC or invented advertisement evidence. Fresh advertisements win;
full protected own-node identity and model verification are still mandatory.
The iOS discovery, refresh and passive reconnect behavior are unchanged.

## Activation phases

| Phase | Owner and behavior | Action |
| --- | --- | --- |
| QR | Host camera reads the printed identity | Physical user action |
| Exact candidate | SDK correlates a fresh discovery snapshot; rejects ambiguity | Automatic |
| BLE connection | Inspection claims ownership and suppresses competing reconnects | Automatic |
| Stock services | Discover required PhoneAPI characteristics | Automatic |
| Security | Protected subscription triggers Android pairing when necessary | System user action if requested |
| Inspection | Request fresh metadata; read model, node, own MAC and firmware | Automatic |
| Eligibility | Verify model 105 and the exact selected identity again | Automatic |
| Artifact | SDK selects and verifies the approved Eixam release | Automatic |
| DFU | One migration-owned native transfer; preserve bond | Automatic |
| DFU reboot | Wait for the device to leave the bootloader | Automatic |
| Reacquisition | Scan and reconnect the retained target; rediscover services | Automatic |
| Firmware verification | Require a connected matching target and expected version | Automatic |
| Country/region | Existing authoritative provisioning coordinator | Automatic |
| SoftSIM | Existing SDK provisioning transport and acknowledgement handling | Automatic |
| Radio/SOS configuration | Existing serialized command/acknowledgement path | Automatic |
| Provisioning reboot | Request reboot and validate its disconnect boundary | Automatic |
| Reconnect/readback | Reconnect the same target and verify live configuration | Automatic |
| Assignment/Ready | Verify assignment before reporting Ready | Automatic |
| App restart | Restore target and lifecycle without re-entering completed DFU | Automatic |

The Android stock test required native pairing consent and PIN entry. Metadata
requesting followed `BOND_BONDED`; the observed repeated-inspection failure was
`metadataTimedOut`, not inspection before bond completion. No custom PIN screen
or manual reboot flow is introduced. Existing Android GATT recovery remains in
place; this correction adds no cache refresh, retry loop or fixed sleep.

## Meshtastic reference

Reference reviewed at Android revision
[`ec1693a`](https://github.com/meshtastic/Meshtastic-Android/tree/ec1693aeeefcbdd049995ac302d12f69c33c665c).
These are behavioral comparisons; no GPL source was copied into the SDK.

| Phase | Meshtastic behavior | Eixam behavior |
| --- | --- | --- |
| Bonding | Await bounded authoritative bond result before arming transport | Existing protected-operation bond wait; native consent |
| Handshake | Ordered, session-owned configuration exchange | Fresh per-inspection request ID; existing exact-target verification |
| DFU ownership | Radio-operation lock isolates transfer | Existing migration-owned Nordic DFU session |
| Post-DFU reconnect | Separate verification stage after upload | Existing reconnect/version-verification stage |
| Fresh advertisement | Prefer address-filtered fresh scan; bounded bonded fallback exists | Existing exact-target migration rediscovery |
| GATT rediscovery | One-shot post-update cache invalidation and rediscovery | Existing Android refresh/discovery policy, unchanged here |
| Firmware verification | View-model waits for connected state and own-node info | Expected firmware identity and selected-target checks |
| Timeout/recovery | Bounded handshake recovery; selected-device transport reconnect can continue | Existing finite inspection stages and durable migration recovery |
| Stranded update | Persist recovery record before bootloader transition | Existing firmware and migration session stores |

Relevant references: [Android bonding](https://github.com/meshtastic/Meshtastic-Android/blob/ec1693aeeefcbdd049995ac302d12f69c33c665c/core/ble/src/androidMain/kotlin/org/meshtastic/core/ble/AndroidBluetoothRepository.kt),
[BLE transport](https://github.com/meshtastic/Meshtastic-Android/blob/ec1693aeeefcbdd049995ac302d12f69c33c665c/core/network/src/commonMain/kotlin/org/meshtastic/core/network/radio/BleRadioTransport.kt),
[firmware verification](https://github.com/meshtastic/Meshtastic-Android/blob/ec1693aeeefcbdd049995ac302d12f69c33c665c/feature/firmware/src/commonMain/kotlin/org/meshtastic/feature/firmware/FirmwareUpdateViewModel.kt),
and stock-bootloader/Legacy DFU changes
[#6041](https://github.com/meshtastic/Meshtastic-Android/pull/6041),
[#6201](https://github.com/meshtastic/Meshtastic-Android/pull/6201),
[#6209](https://github.com/meshtastic/Meshtastic-Android/pull/6209),
[#5915](https://github.com/meshtastic/Meshtastic-Android/pull/5915),
[#5916](https://github.com/meshtastic/Meshtastic-Android/pull/5916).

## Validation boundary

The regression transport retains a physical link across separately constructed
inspection operations and suppresses duplicate requests, matching the stock
buffer behavior. Both operations must return the same authoritative identity.
Existing iOS retained-link, security, identity and cleanup tests remain guards.

The initial Android STAGING run used restored official stock 2.7.26, bootloader
0.4.3 and SoftDevice 6.1.1. Repeated inspection failed twice after successful
bonding; a retained-target recovery subsequently completed one approved DFU and
provisioning through Ready. Physical stock activation with the corrected SDK is
a separate acceptance requirement; unit tests do not establish that result.
