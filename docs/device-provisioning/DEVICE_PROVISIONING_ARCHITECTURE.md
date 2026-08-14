# Eixam Device Provisioning Architecture

Status: canonical internal provisioning reference for SDK Phase 2A

Snapshot date: 2026-08-14

Audience: SDK, firmware, backend, application, QA, and release engineers

> **Certification boundary:** firmware `2.7.34` is **not certified for
> mutating SDK provisioning**. The production SDK policy is deliberately
> closed, so the current implementation cannot send provisioning writes to a
> real TAG. See [Firmware compatibility policy](#23-firmware-compatibility-policy).

This document separates three kinds of statement:

- **Implemented contract** — present in the reviewed Phase 2A SDK or confirmed
  directly in current firmware/backend source.
- **Current certification status** — an implemented path that remains disabled
  until the firmware is corrected and certified.
- **External follow-up** — work owned outside this SDK change.

## Contents

1. [Purpose and scope](#1-purpose-and-scope)
2. [Current development snapshot](#2-current-development-snapshot)
3. [Responsibility boundaries](#3-responsibility-boundaries)
4. [Device identity model](#4-device-identity-model)
5. [Backend authentication and effective PSK](#5-backend-authentication-and-effective-psk)
6. [RF provisioning backend contract](#6-rf-provisioning-backend-contract)
7. [BLE service and characteristics](#7-ble-service-and-characteristics)
8. [Command overview](#8-command-overview)
9. [`0x23` device status contract](#9-0x23-device-status-contract)
10. [Device readiness and assignment semantics](#10-device-readiness-and-assignment-semantics)
11. [`0x20` full TEL RF contract](#11-0x20-full-tel-rf-contract)
12. [`0x21` SOS RF contract](#12-0x21-sos-rf-contract)
13. [`0x22` reboot contract](#13-0x22-reboot-contract)
14. [`0x24` SoftSIM blob](#14-0x24-softsim-blob)
15. [SoftSIM CRC32](#15-softsim-crc32)
16. [SoftSIM transport](#16-softsim-transport)
17. [SoftSIM REJECT handling](#17-softsim-reject-handling)
18. [`E9 7A` command-result contract](#18-e9-7a-command-result-contract)
19. [ACK safety and connection epoch](#19-ack-safety-and-connection-epoch)
20. [PSK runtime application](#20-psk-runtime-application)
21. [Canonical `ensureDeviceReady` flow](#21-canonical-ensuredeviceready-flow)
22. [Final verification](#22-final-verification)
23. [Firmware compatibility policy](#23-firmware-compatibility-policy)
24. [Current external firmware blockers](#24-current-external-firmware-blockers)
25. [Failure and retry model](#25-failure-and-retry-model)
26. [Security model](#26-security-model)
27. [Cancellation and lifecycle safety](#27-cancellation-and-lifecycle-safety)
28. [Public SDK API](#28-public-sdk-api)
29. [Testing status](#29-testing-status)
30. [Physical E2E plan](#30-physical-e2e-plan)
31. [Production release gate](#31-production-release-gate)
32. [Known non-goals](#32-known-non-goals)
33. [Change history and milestones](#33-change-history-and-milestones)
34. [Next actions](#34-next-actions)
35. [Source map](#35-source-map)

## 1. Purpose and scope

Device provisioning turns a connected virgin Eixam TAG into a device whose
private mesh material, product identity, radio plan, and runtime state are
configured coherently. It is not synonymous with BLE pairing or product
activation.

Provisioning belongs in `eixam-sdk-flutter` because it coordinates contracts
owned by several systems: signed backend requests, secret lifetime, strict
radio parsing, BLE framing, asynchronous firmware results, reboot timing,
reconnection, identity continuity, and final verification. Moving any part of
that state machine into a host application would duplicate security-sensitive
protocol logic and allow partner behavior to diverge.

```text
Firmware + Backend
        |
        v
Eixam Flutter SDK
        |
        v
Commercial App / Demo / Partner Apps
```

Applications consume semantic actions and state. They must not construct
provisioning frames, fetch or compare PSKs, interpret raw result packets, choose
radio wire values, calculate CRCs, or manage provisioning retries.

At the SDK level, **ready** means a complete SDK-controlled provisioning flow
has succeeded and, after the commanded reboot, the SDK has reconnected to the
same platform BLE device and obtained fresh runtime evidence showing the same
firmware node identity and expected operational configuration. A TAG that was
already provisioned outside the current operation is not automatically called
ready because `PROVISIONED=1` does not prove current-app assignment.

## 2. Current development snapshot

| Component | Audited state |
| --- | --- |
| SDK branch | `feat/device-provisioning-phase2` |
| SDK Phase 1/base commit | `b924659ea41a60b6b11e8432142b0b0073fe083d` |
| SDK Phase 2A | Reviewed, uncommitted working-tree implementation when this document was created |
| D3 semantic TAG positions | `b2bf27e893078189ce43236471c9a4b4293087bb` |
| Firmware version | `2.7.34` |
| Firmware audited main | `865722b02ade21054fc88f733b73649885db257c` |
| Backend audited main | `fd284b6debe37f5021345fbc60c1b60ff022bc40` |

**Firmware `2.7.34` is not certified for mutating SDK provisioning.** The SDK
uses `ProvisioningFirmwarePolicy.pendingCertification()`, whose minimum version
is unset and whose compatibility decision is therefore always false. This is
an intentional release barrier, not an incomplete SDK execution path.

## 3. Responsibility boundaries

```text
Backend                    SDK                         Firmware
--------                   ---                         --------
signed PSK/config  --->    validate + orchestrate ---> validate + persist
                           encode + protect secrets    apply RF/PSK
                           reboot/reconnect/verify <--- status + command result
                                  |
                                  v
                         semantic app API
```

| Owner | Responsibilities |
| --- | --- |
| Firmware | `config.bin`/NVM; commands `0x20`–`0x24`; SoftSIM validation and CRC verification; PSK application; RF validation and persistence; command-result notifications; reboot; post-boot runtime modules |
| Backend | Effective network PSK; app-specific-to-global resolution; SDK authentication; device registration; `hardware_id` storage; country-to-RF configuration distribution |
| SDK | End-to-end orchestration; backend calls; strict response parsing; PSK lifetime; `backendToken`; exact decimal conversion; BLE encoding; CRC construction; chunking; asynchronous REJECT observation; ACK serialization; timeout and connection-epoch policy; reboot/reconnect; same-device verification; firmware gate; public state and typed failures |
| Applications | Presentation, localization, navigation, retry CTA, and user-facing explanations derived from typed SDK state |

Applications must not own opcode selection, raw packet parsing, ACK matching,
SoftSIM layout, RF conversion, firmware compatibility decisions, or secret
material.

## 4. Device identity model

| Identity | Meaning | Provisioning use |
| --- | --- | --- |
| Platform BLE ID | Android/iOS identifier used to address the current BLE peripheral | Reconnect and same-platform-device verification |
| BLE MAC | Hardware address where the platform makes one available | Diagnostics/transport identity only; not the SoftSIM token |
| Firmware `nodeId` | Unsigned 32-bit Meshtastic/Eixam node number returned by fresh `0x23` | Canonical provisioning hardware identity |
| Backend `hardware_id` | Public string used to associate backend device records and device-origin traffic | Exact unsigned decimal representation of `nodeId` |
| Backend device UUID | Database row identity | Backend-internal; never substituted for `backendToken` |
| App ID | Identifies the integrating SDK application | Signed SDK authentication and backend scoping |
| External user ID | Partner-controlled user identity within the app | Signed SDK authentication and user association |

The owner-confirmed mapping is:

```text
firmware nodeId
    -> unsigned decimal string
    -> backend hardware_id
    -> SoftSIM backendToken
```

Fake example:

```text
nodeId      = 305419896
hardware_id = "305419896"
backendToken bytes begin with ASCII "305419896"
```

The representation is decimal, not hexadecimal. It is a public identifier,
not a credential. In the SoftSIM blob it is ASCII, NUL-terminated, and
zero-padded to 64 bytes. Do not substitute a BLE MAC, platform BLE ID, or
backend database UUID. Historical firmware notes described the token
differently; the current SDK intentionally implements the owner-confirmed
`hardware_id` contract.

## 5. Backend authentication and effective PSK

The SDK obtains provisioning material with:

```http
GET /v1/sdk/network/psk
X-App-ID: partner-app
X-User-ID: partner-user-123
Authorization: Bearer <signed-user-hash>
```

The signed-session headers are added by the common SDK HTTP transport. A
successful response has this contract:

```json
{
  "psk": "<64 lowercase hexadecimal characters>",
  "algorithm": "AES-256",
  "bytes": 32,
  "scope": "app"
}
```

`scope` is either `app` or `global`. Resolution is server-authoritative:

```text
app-specific PSK
        |
        v fallback when absent
global PSK
```

The SDK must not reproduce or second-guess that fallback. It strictly requires
a successful response, a 64-character lowercase hexadecimal PSK, algorithm
`AES-256`, byte count 32, and a supported scope. The decoded PSK is held in a
mutable internal buffer, is never exposed through the public API, and is
zeroed after its last use.

Implementation sources:
`packages/eixam_connect_flutter/lib/src/data/datasources_remote/sdk_network_psk_remote_data_source.dart`
and `eixam-platform/api/services/networkpsk/`.

## 6. RF provisioning backend contract

The SDK resolves the country and requests:

```http
GET /v1/sdk/device-configs?country_iso=<ISO>
```

The backend currently stores and returns the selected device configuration as
free-form JSON. Phase 2A does not trust that shape implicitly: it strict-parses
the required fields and accepts only the source-certified EU868 plan below.

```json
{
  "lora_region_code": 3,
  "plan_verified": true,
  "region": "EU868",
  "tel": {
    "freq_mhz": 866.5,
    "bw_khz": 250,
    "sf_default": 9,
    "cr": "4/5",
    "tx_power_uplink_dbm": 14
  },
  "sos": {
    "freq_mhz": 869.4625,
    "bw_khz": 62.5,
    "sf": 12,
    "cr": "4/8",
    "tx_power_dbm": 22,
    "preamble_symbols": 8
  }
}
```

No provisioning fallback or legacy default is allowed. A missing, malformed,
unverified, non-EU868, or unsupported plan produces `configurationInvalid` or
`configurationUnavailable` before mutation. Adding another region requires an
explicit source-certified plan and SDK validation update.

### Exact conversions

| Backend value | Wire value |
| --- | --- |
| TEL `freq_mhz` | MHz × 1,000 → integer kHz |
| SOS `freq_mhz` | MHz × 1,000,000 → integer Hz |
| SOS `bw_khz` | kHz × 1,000 → integer Hz |
| `cr: "4/N"` | denominator `N` |

The SDK parses the JSON number's canonical decimal representation into a
rational integer calculation using `BigInt`. It requires exact divisibility,
rejects overflow, and never silently rounds binary floating-point values.
Examples include `866.5 -> 866500`, `869.4625 -> 869462500`, `62.5 -> 62500`,
and `128.002 × 1000 -> 128002`. Exponent notation is supported when it denotes
an exact target integer.

## 7. BLE service and characteristics

The canonical UUID definitions remain in
`packages/eixam_connect_flutter/lib/src/device/eixam_ble_protocol.dart`; the
broader BLE integration contract remains in
`packages/eixam_connect_flutter/BLE_DEVICE_CONTRACT.md`.

| Suffix | Role |
| --- | --- |
| `ea00` | Eixam service |
| `ea01` | TEL notifications, including runtime status and command results |
| `ea02` | SOS notifications |
| `ea03` | INET/small command write path |
| `ea04` | CMD/larger command write path |

Provisioning commands are forced through CMD (`ea04`). Its current application
payload limit is 16 bytes, which determines the 12-byte SoftSIM CHUNK data
limit after the four-byte CHUNK header.

## 8. Command overview

| Opcode | Purpose |
| --- | --- |
| `0x20` | Full TEL/LoRa RF configuration; a legacy short region form also exists |
| `0x21` | SOS RF configuration |
| `0x22` | Reboot to apply persisted configuration/runtime policy |
| `0x23` | Request runtime/device status |
| `0x24` | Transactional SoftSIM provisioning |

`0xD3` is a live batched-position telemetry payload. It is not a provisioning
command; it becomes relevant after a provisioned reboot starts the Eixam
runtime modules. Provider routing distinguishes `E9 7A`, `E9 78`, D3, classic
TEL, and SOS by complete packet contracts rather than weak first-byte checks.

## 9. `0x23` device status contract

Request:

```text
[0x23]
```

Response: exactly 14 bytes with versioned header `E9 78 02`.

| Offset | Size | Meaning |
| ---: | ---: | --- |
| 0 | 1 | `0xE9` magic |
| 1 | 1 | `0x78` device-status type |
| 2 | 1 | `0x02` contract version |
| 3 | 1 | Meshtastic region code |
| 4 | 1 | modem preset |
| 5 | 1 | effective mesh spreading factor |
| 6 | 1 | status flags |
| 7 | 4 | firmware `nodeId`, unsigned u32 little-endian |
| 11 | 1 | battery percent; values above 100 mean unavailable |
| 12 | 2 | TEL interval seconds, u16 little-endian |

Flag byte:

| Bit | Mask | Meaning |
| ---: | ---: | --- |
| 0 | `0x01` | `PROVISIONED`: firmware has structurally valid Eixam NVM/config |
| 1 | `0x02` | LoRa `usePreset` |
| 2 | `0x04` | LoRa TX enabled |
| 3 | `0x08` | latest INET state is OK |
| 4 | `0x10` | position confirmed |

`PROVISIONED=1` proves structural firmware configuration state. It does not
prove that the current application owns the stored PSK or that the current
backend assignment matches it.

The SDK maps authoritative runtime evidence to
`DeviceProvisioningStatus.unknown`, `.unprovisioned`, or `.provisioned`.
Provisioning status is not restored as an authoritative cached checkpoint.

```text
activated != provisioned != txEnabled
```

- `activated` is a product/backend lifecycle concept.
- `provisioned` is firmware NVM/config validity.
- `txEnabled` is current LoRa runtime configuration.

None implies either of the others.

## 10. Device readiness and assignment semantics

A TAG can be:

1. **Unprovisioned** — fresh `0x23` reports no structurally valid provisioning.
2. **Provisioned, assignment unverified** — fresh `0x23` reports provisioned,
   but the SDK has not proven current-app PSK/backend ownership.
3. **Ready** — the current SDK operation completed mutation, reboot,
   same-device reconnect, and fresh runtime verification.

An already-provisioned TAG is not rewritten automatically. Rewriting could
silently move a device between app-specific network assignments. Instead,
`ensureDeviceReady()` returns
`DeviceReadyDisposition.provisionedAssignmentUnverified`, without fetching a
PSK or issuing provisioning writes. A future explicit reassignment flow may
resolve this ambiguity, but it is not part of Phase 2A.

## 11. `0x20` full TEL RF contract

Phase 2A sends the exact 12-byte full form:

| Offset | Size | Meaning |
| ---: | ---: | --- |
| 0 | 1 | `0x20` |
| 1 | 1 | region code; EU868 is `3` |
| 2 | 1 | full RF version `0x01` |
| 3 | 4 | TEL center frequency in kHz, u32 little-endian |
| 7 | 2 | TEL bandwidth in kHz, u16 little-endian |
| 9 | 1 | spreading factor |
| 10 | 1 | coding-rate denominator |
| 11 | 1 | TX power in dBm, signed i8 |

The accepted source-certified EU868 constraints are:

- region code 3 and textual region `EU868`;
- `plan_verified=true`;
- TEL channel fully contained within 865–868 MHz;
- bandwidth exactly 250 kHz;
- SF 7–9, with backend default currently 9;
- coding rate exactly 4/5;
- uplink power 0–14 dBm.

Firmware still supports a legacy short `0x20` region form. The readiness
orchestrator does not use it.

The SDK waits for a matching command result. `OK` and `OK_NOCHANGE` are both
semantic success for `0x20`; `REJECT` is failure. In firmware, detail normally
contains the region code.

**Current certification caveat:** audited firmware `2.7.34` still has a
persistence/idempotency behavior awaiting Joan's final correction. It is not
approved for this mutating flow.

## 12. `0x21` SOS RF contract

Phase 2A sends exactly 14 bytes:

| Offset | Size | Meaning |
| ---: | ---: | --- |
| 0 | 1 | `0x21` |
| 1 | 1 | version `0x01` |
| 2 | 4 | SOS center frequency in Hz, u32 little-endian |
| 6 | 4 | SOS bandwidth in Hz, u32 little-endian |
| 10 | 1 | spreading factor |
| 11 | 1 | coding-rate denominator |
| 12 | 1 | TX power in dBm, signed i8 |
| 13 | 1 | preamble symbols |

The current certified EU868 values are 869,462,500 Hz, 62,500 Hz bandwidth,
SF12, coding rate 4/8, 22 dBm, and preamble 8. The entire channel must fit in
the firmware SOS band 869.4–869.65 MHz.

Firmware validates and persists the complete SOS RF record. Sending the same
valid record is operationally idempotent: it persists the same values and
returns `OK`. Unlike `0x20`, the SDK does not accept `OK_NOCHANGE` for `0x21`
under the current contract.

## 13. `0x22` reboot contract

Request:

```text
[0x22]
```

Firmware schedules reboot approximately 1.5 seconds after receiving it. The
SDK subscribes for disconnect before issuing the write, then measures from
successful write completion.

The current conservative acceptance window is 900 ms through 5 seconds:

- disconnect before 900 ms: unexpected/premature, `rebootFailed`;
- disconnect inside the window: expected reboot, proceed to reconnect;
- no disconnect by 5 seconds: `rebootFailed`;
- reconnect must target the same platform BLE device.

The lower bound leaves margin around firmware's 1.5-second schedule while
rejecting an unrelated immediate transport loss. The upper bound allows normal
Android/iOS callback scheduling without treating an indefinite disconnect as
success.

## 14. `0x24` SoftSIM blob

SoftSIM is exactly 230 bytes:

```text
+---------+--------+--------------------+
| Offset  | Size   | Field              |
+---------+--------+--------------------+
| 0       | 32     | PSK                |
| 32      | 64     | backendToken       |
| 96      | 128    | backendUrl         |
| 224     | 4      | telIntervalMs LE   |
| 228     | 1      | telSFDefault       |
| 229     | 1      | sosPower (i8)      |
+---------+--------+--------------------+
```

| Field | Current SDK source |
| --- | --- |
| PSK | Effective 32-byte PSK from `GET /v1/sdk/network/psk` |
| `backendToken` | `nodeId.toString()` using unsigned decimal representation |
| `backendUrl` | API base URL resolved by SDK bootstrap/environment |
| `telIntervalMs` | Canonical initial value `120000` |
| `telSFDefault` | Strict RF configuration TEL SF |
| `sosPower` | Strict RF configuration SOS TX power |

`backendToken` and `backendUrl` must fit their fixed-width fields as
ASCII-compatible C strings. Each is NUL-terminated and zero-padded. The PSK and
all `0x24` frames are classified as secret. The blob never enters the public
SDK model.

## 15. SoftSIM CRC32

The SDK and firmware use reflected IEEE CRC-32:

- polynomial: `0xEDB88320`;
- initial value: `0xFFFFFFFF`;
- final XOR: `0xFFFFFFFF`;
- input: all 230 SoftSIM bytes in layout order;
- BEGIN serialization: u32 little-endian.

Known vector:

```text
"123456789" -> 0xCBF43926
```

The CRC detects incomplete, reordered, or corrupted transport data. It is an
integrity check, not authentication or encryption.

## 16. SoftSIM transport

Frames use these exact forms (hexadecimal bytes):

```text
BEGIN  [0x24 0x01][totalLen u16 LE][crc32 u32 LE]
CHUNK  [0x24 0x02][offset u16 LE][data...]
COMMIT [0x24 0x03]
ABORT  [0x24 0x04]
```

BEGIN is 8 bytes. COMMIT and ABORT are 2 bytes. CMD (`ea04`) permits a 16-byte
application payload, so CHUNK has four header bytes and at most 12 data bytes.

For the 230-byte blob, the SDK sends exactly 20 contiguous CHUNK frames:

```text
0, 12, 24, 36, 48, 60, 72, 84, 96, 108,
120, 132, 144, 156, 168, 180, 192, 204, 216, 228
```

The final frame carries 2 data bytes. Offsets are absolute blob offsets and
firmware requires each offset to equal the number of bytes already received.

The encoder supports ABORT, but cancellation/disposal deliberately sends no
best-effort ABORT because the lifecycle guarantee is no new writes after
cancellation. Firmware clears abandoned state on disconnect or its session
timeout.

Transport flow:

```text
build 230-byte blob
        |
        v
BEGIN(length + CRC)
        |
        v
20 sequential CHUNK writes
        |
        v
COMMIT + matching ACK
        |
        v
zero SDK-owned frame/blob buffers
```

## 17. SoftSIM REJECT handling

Valid BEGIN and CHUNK frames have no positive semantic ACK. Firmware can emit
an asynchronous `REJECT` after processing an invalid frame. Advancing after an
event-loop turn or repeatedly replacing subscriptions could miss that result.

Phase 2A therefore uses:

- one continuous transaction-scoped REJECT observer;
- observer active before BEGIN through the COMMIT ACK handoff;
- no subscription gap between the final CHUNK and COMMIT waiter;
- 250 ms observation after BEGIN and after every CHUNK;
- immediate cancellation of further writes when REJECT is observed.

Firmware's bridge drains notification queues approximately every 100 ms. The
250 ms interval covers two complete drain cycles plus scheduling margin;
`Duration.zero` would not. BEGIN plus 20 CHUNK observation periods total:

```text
21 × 250 ms = 5.25 seconds
```

This is comfortably inside the 30-second firmware SoftSIM session timeout
under normal BLE operation. Every accepted CHUNK also refreshes firmware's
last-activity timestamp, so the meaningful timeout gap is per frame rather
than the cumulative transfer duration.

## 18. `E9 7A` command-result contract

A command result is exactly six bytes:

```text
E9 7A 01 [opcode] [result] [detail]
```

| Result | Meaning |
| ---: | --- |
| `0x00` | `OK` |
| `0x01` | `OK_NOCHANGE` |
| `0x02` | `REJECT` |

The SDK waits for a result for full `0x20`, `0x21`, and `0x24` COMMIT. For
COMMIT it additionally requires detail `0x03`. BEGIN/CHUNK use the continuous
asynchronous REJECT monitor and do not invent positive acknowledgements.

```text
E9 78 -> device status
E9 7A -> command result
```

The strict parser requires exact packet length, magic, version, result enum,
expected opcode, and any required detail. The provider emits command results
to the internal provisioning stream and does not route them into TEL, D3, or
SOS processing.

## 19. ACK safety and connection epoch

`E9 7A` has no transaction ID. After a timeout, a late ACK for an earlier
same-opcode command is indistinguishable from an ACK for a new command on the
same BLE connection. A local counter cannot repair that missing wire identity.

The SDK policy is:

1. Only one ACK-bearing provisioning command may be outstanding.
2. The waiter and timeout are installed before the BLE write.
3. Timeout or uncertain write poisons the current connection epoch.
4. No further mutating ACK transaction may begin on that epoch.
5. An observed disconnect followed by reconnect establishes a fresh epoch.
6. Packets received without a valid matching waiter are ignored.

Pending waiters and timers are cleared on success, timeout, REJECT,
disconnect, cancellation, unexpected write failure, and disposal. Disconnect
during a wait produces `deviceCommunicationInterrupted`, not a misleading
command timeout.

## 20. PSK runtime application

Firmware behavior is:

```text
0x24 SoftSIM
    -> config.bin
    -> EixamChannelCrypto
    -> PRIMARY Meshtastic channel
```

Firmware applies the PSK to PRIMARY during COMMIT and reapplies it at boot
after loading channel state. PRIMARY carries normal Eixam mesh cryptography,
including TEL/heartbeat/cluster/rescue and mesh SOS paths that use the normal
Meshtastic channel.

The dedicated raw SOS radio path is separate. It uses the SOS RF configuration
but does not use the PRIMARY channel PSK. These two transport/security domains
must not be conflated.

## 21. Canonical `ensureDeviceReady` flow

This is the actual Phase 2A source ordering:

```text
connected TAG / refreshed DeviceStatus
        |
        v
fresh 0x23 + node identity check
        |
        +-- already provisioned --> assignment unverified; no PSK/writes
        |
        v
resolve country + strict RF config
        |
        v
forced live firmware read / certification gate
        |
        v
fetch effective PSK
        |
        v
second forced live firmware safety check
        |
        v
build 230-byte SoftSIM
        |
        v
0x24 BEGIN -> 20 CHUNK -> COMMIT + ACK
        |
        v
0x20 full TEL RF + ACK
        |
        v
0x21 SOS RF + ACK
        |
        v
0x22 reboot
        |
        v
expected disconnect in 900 ms..5 s
        |
        v
same-platform-device reconnect
        |
        v
refreshed DeviceStatus + fresh 0x23
        |
        v
same nodeId + runtime verification
        |
        v
READY
```

The first `0x23` is intentionally before the firmware gate because it is
non-mutating and enables the already-provisioned short circuit. The first live
firmware gate occurs before PSK retrieval, and the second occurs after that
network await immediately before secret construction and mutation. A stale
cached firmware version cannot authorize writes.

Every awaited boundary checks cancellation. Every terminal validation failure
returns immediately or throws into the typed failure mapping; there is no
fall-through into later writes.

## 22. Final verification

READY requires all of the following after reboot:

- the same platform BLE identity is connected;
- a fresh direct `0x23` request completes;
- returned `nodeId` equals the pre-provisioning node ID;
- `isProvisioned` is true;
- region equals the strict expected region;
- `usePreset` is false;
- `txEnabled` is true;
- effective mesh SF equals the expected TEL SF.

The runtime request installs a new pending request before writing `0x23`, so a
cached pre-reboot status cannot satisfy it. Wrong platform identity fails
before final runtime verification; wrong node identity produces
`identityMismatch`; other mismatches produce `verificationFailed`.

## 23. Firmware compatibility policy

> **CURRENT CERTIFICATION STATUS**
>
> ```text
> Firmware 2.7.34: NOT CERTIFIED
> ```

Production wiring constructs:

```dart
const ProvisioningFirmwarePolicy.pendingCertification()
```

An unset certified minimum rejects every firmware version, including `2.7.34`
and hypothetical newer versions. For a virgin TAG, the live firmware gate
therefore returns `firmwareUpdateRequired` before PSK retrieval or mutation.

The zero-write consequence is explicit:

- no `0x24` BEGIN/CHUNK/COMMIT;
- no provisioning `0x20`;
- no `0x21`;
- no provisioning `0x22` reboot.

The final minimum version will be configured only after Joan's firmware fixes,
a version bump, and focused firmware microaudit. This document does not guess
the eventual version number.

## 24. Current external firmware blockers

These are external certification blockers, not SDK correctness defects.

### Blocker A — `0x20` persistence/idempotency

Current `2.7.34` may mutate RAM, fail persistence, return `REJECT`, then return
a false `OK_NOCHANGE` when the same state is retried. Joan is correcting the
persistence/idempotency behavior so the result truthfully represents durable
state.

### Blocker B — `0x24` COMMIT truthfulness

Current `2.7.34` may save `config.bin`, fail to apply or persist the PRIMARY
PSK, and still return `OK`. Joan is correcting COMMIT so success means all
required durable/runtime effects succeeded.

### Blocker C — final firmware certification

After both fixes:

1. bump the firmware version;
2. run the focused firmware microaudit;
3. configure the SDK's certified minimum;
4. run the physical E2E sequence.

Until those steps finish, firmware `2.7.34` remains blocked regardless of the
completeness of the SDK implementation.

## 25. Failure and retry model

Partner applications consume semantic failures, never opcode/result details.

| Public code/result | Meaning | Current retry guidance |
| --- | --- | --- |
| `notConnected` | No connected device/node identity | Retry after connection recovery |
| `firmwareUpdateRequired` | Live firmware version is not accepted by the certification policy | Not retryable without a certified firmware change |
| `configurationUnavailable` | Required provisioning dependency/backend configuration unavailable | Current mapping is non-retryable except where a distinct timeout is known |
| `configurationInvalid` | Backend/material contract malformed or unsupported | Not retryable until configuration is corrected |
| `backendTimeout` | Required backend operation timed out | Retryable |
| `deviceCommunicationTimeout` | Expected device response did not arrive | Retryable after connection recovery |
| `deviceCommunicationInterrupted` | Disconnect, poisoned epoch, uncertain transport, or cancellation | Retryable after a clean connection |
| `deviceConfigurationRejected` | Device rejected the requested configuration | Not automatically retryable |
| `rebootFailed` | Reboot disconnect was premature or absent | Retryable after inspecting connection/device state |
| `reconnectFailed` | SDK could not reconnect to the same device | Retryable |
| `identityMismatch` | Platform or firmware node identity changed | Not retryable as the same operation; requires user/device resolution |
| `verificationFailed` | Fresh post-reboot runtime state differs from expectations | Retryable only after diagnosing device state |
| `internal` | Unexpected SDK failure | Marked retryable, with diagnostics/support follow-up |

`provisionedAssignmentUnverified` is a disposition, not a failure. It tells the
application that firmware provisioning exists but current-app ownership cannot
be proven. Applications should present an assignment/recovery explanation, not
a generic transport retry.

Failure to read live firmware metadata is fail-closed before mutation and maps
through the communication timeout/interruption families; it cannot authorize
provisioning from cached metadata.

## 26. Security model

### SDK secret handling

- The PSK is private implementation data with no public getter.
- The SDK does not persist the provisioning PSK.
- Provisioning secrets must not enter logs, analytics, crash payloads, or
  public state.
- Every `0x24` command is secret-classified, even if a caller incorrectly asks
  for an operational classification.
- Secret `encodedHex` and diagnostic payloads return redacted text.
- The transport still receives raw binary bytes through the internal write
  path.
- PSK, token bytes, URL bytes, SoftSIM blob, frame buffer, and command-owned
  payload copies are mutable and zeroed after their last awaited use.
- Frames are generated and written sequentially; there is no prebuilt cache of
  20 secret CHUNK frames.
- Cleanup occurs through `finally` on success, REJECT, exception, timeout, and
  cancellation paths.

Zeroization in managed Dart is best-effort. It clears buffers the SDK owns, but
cannot prove removal of VM/runtime copies, immutable `String` storage, OS BLE
stack copies, or hardware buffers. This limitation is why the design also
minimizes copies, keeps lifetime short, and prohibits diagnostics exposure.

### Backend production hardening

Two backend hardening tasks remain required before production:

- redact plaintext PSK bodies from admin get/create/update responses and any
  associated administrative logging surface;
- add `Cache-Control: no-store` to secret PSK responses.

These are must-fix production controls, but they do not block controlled
staging development of the SDK protocol.

## 27. Cancellation and lifecycle safety

Each readiness run has an internal operation identity and cancellation signal.
The coordinator checks it before every new write and after each awaited step.

- `dispose()` marks the active operation cancelled.
- A BLE write already executing at the platform boundary may finish; Dart
  cannot forcibly cancel that Future.
- After the current awaited write settles, no subsequent CHUNK, COMMIT, RF, or
  reboot write is issued.
- Cancellation removes the SoftSIM observer and pending ACK waiter.
- Secret cleanup still runs.
- Disposal suppresses later state publication, including READY.
- Unexpected disconnect cancels active work and resets readiness.
- A connected-device identity change cancels active work and resets readiness.
- Expected reboot disconnect is handled specially so it does not cancel the
  intended reconnect flow.
- READY for device A cannot remain published when device B becomes active.

The ACK coordinator maintains a separate connection-validity epoch because
operation cancellation alone cannot isolate transaction-less stale packets.

## 28. Public SDK API

The Phase 2 public methods are:

```dart
Future<DeviceReadyResult> ensureDeviceReady();
Stream<DeviceProvisioningState> watchDeviceProvisioningState();
```

The public result is:

```dart
enum DeviceReadyDisposition {
  ready,
  provisionedAssignmentUnverified,
  failed,
}
```

Provisioning phases are:

```dart
enum DeviceProvisioningPhase {
  idle,
  checkingDevice,
  provisionedAssignmentUnverified,
  firmwareUpdateRequired,
  fetchingConfiguration,
  provisioning,
  applyingRadioConfiguration,
  rebooting,
  reconnecting,
  verifying,
  ready,
  failed,
}
```

`DeviceReadyResult` contains the disposition, a `DeviceStatus` for successful
or assignment-unverified outcomes, or a semantic `DeviceReadyFailure` for
failure. `DeviceReadyFailure` contains an exact public failure code and a
`retryable` boolean.

Numeric progress is optional, constrained to the inclusive range 0–1, and
monotonic within one operation. Current numeric milestones are 0, 0.5, 0.7,
0.8, 0.9, and 1. Returning to `idle` resets progress.

Minimal host usage:

```dart
final subscription = sdk.watchDeviceProvisioningState().listen((state) {
  // Render localized UI from state.phase, state.progress, and state.failure.
});

final result = await sdk.ensureDeviceReady();
if (result.isReady) {
  // Continue onboarding.
} else if (result.disposition ==
    DeviceReadyDisposition.provisionedAssignmentUnverified) {
  // Explain that assignment must be verified before continuing.
} else {
  // Present semantic recovery using result.failure.
}
```

`connectDevice({required String pairingCode})` remains a separate operation.
Connecting or pairing does not silently provision a TAG. Applications do not
receive PSKs, backend tokens, SoftSIM fields, opcodes, raw RF wire values, CRCs,
chunk indexes, ACK packets, or BLE characteristic decisions.

## 29. Testing status

Validated at documentation creation:

| Validation | Result |
| --- | --- |
| Full Flutter SDK suite | 797 passing |
| Core Dart suite | 132 passing |
| Focused provisioning suite | 52 passing |
| Provider routing/SOS/D3 suite | 19 passing |
| `flutter analyze --no-fatal-infos` | No errors or warnings; 3 pre-existing informational implementation-import notices |
| `git diff --check` | Clean |

High-value covered scenarios include:

- delayed BEGIN, middle-CHUNK, final-CHUNK, and COMMIT-handoff REJECT;
- stale ACK after timeout and connection-epoch recovery;
- immediate ACK, wrong opcode/detail, malformed result, and timeout boundary;
- disconnect during ACK wait;
- cancellation/disposal during BEGIN and CHUNK with no later writes;
- secret diagnostics redaction and buffer cleanup after success/failure/timeout;
- stale cached firmware overridden by a live unsupported version;
- pending-certification zero-write behavior;
- already-provisioned assignment-unverified behavior;
- reboot lower bound, accepted disconnect, and missing disconnect;
- reconnect platform identity, node identity, and fresh final `0x23`;
- exact RF decimal conversion, exponent input, fractional rejection, and overflow;
- strict source-certified EU868 constraints;
- `E9 7A`/`E9 78`/D3/TEL/SOS routing without collisions;
- D3-shaped SOS/TEL collision regressions and existing SOS regressions.

Automated tests establish implementation behavior. They do not replace the
physical certification gate.

## 30. Physical E2E plan

Run only after corrected firmware has been versioned and certified:

```text
TAG currently on 2.7.31
    -> flash final certified firmware
    -> verify live BLE firmware revision
    -> fresh 0x23 reports unprovisioned
    -> ensureDeviceReady()
    -> expected reboot and reconnect
    -> fresh 0x23 reports provisioned and expected runtime state
    -> verify TEL
    -> verify D3 live batch
    -> trigger SOS
    -> verify backend processing
    -> cancel SOS
    -> power cycle TAG
    -> reconnect
    -> verify PSK/RF/config persistence
```

Negative and recovery coverage:

- interrupt SoftSIM during BEGIN, a middle CHUNK, and before COMMIT;
- disconnect and reconnect before retrying a poisoned transaction;
- present the wrong platform device and wrong node identity;
- make RF/PSK backend calls fail and time out;
- retry only through semantic SDK policy;
- confirm no raw PSK, SoftSIM bytes, token, or authorization value appears in
  application logs, SDK diagnostics, platform logs, analytics, or crash data.

Record firmware build identity, mobile platform/version, TAG identity, backend
environment, timestamps, and semantic outcomes without recording secrets.

## 31. Production release gate

- [ ] Joan's final `0x20` persistence/idempotency correction is merged.
- [ ] Joan's truthful `0x24` COMMIT correction is merged.
- [ ] Firmware version is bumped; it is not assumed in advance.
- [ ] Focused firmware microaudit passes.
- [ ] SDK certified minimum firmware is configured in a small reviewed patch.
- [ ] SDK analyze and full/focused tests pass at the release head.
- [ ] Physical provisioning E2E passes on supported mobile platforms.
- [ ] TEL operation passes after provisioning and power cycle.
- [ ] D3 live-batch operation and routing pass.
- [ ] SOS trigger, backend handling, and cancellation pass.
- [ ] Backend admin PSK bodies/logging are hardened.
- [ ] Secret PSK responses use `Cache-Control: no-store`.
- [ ] Demo integration is validated against a committed SDK revision.
- [ ] Commercial app integration is validated against a committed SDK revision.
- [ ] Partner-facing documentation reflects the certified release behavior.

No single checked item overrides the others. In particular, a green SDK suite
does not certify firmware, and a firmware version bump without microaudit and
physical E2E does not open the SDK gate.

## 32. Known non-goals

Phase 2A does not include:

- automatic reprovisioning of an already-provisioned TAG;
- automatic app reassignment or ownership transfer;
- multi-region RF support beyond source-certified EU868;
- a raw provisioning API for partner applications;
- firmware OTA/DFU implementation changes;
- backend schema redesign solely to replace free-form configuration JSON;
- cryptographic proof of current-app assignment for pre-provisioned devices;
- full RF parameter readback after reboot.

Once firmware ACKs are truthful, command ACK plus fresh final `0x23` is the
intended MVP verification model. The ACK proves that the requested persistent
operation reported success; the fresh status proves identity, provisioning,
region, preset policy, TX enablement, and effective SF after reboot. Full RF
readback could strengthen a future protocol but is not required for this MVP.

## 33. Change history and milestones

| Milestone | Revision/state | Significance |
| --- | --- | --- |
| D3 semantic TAG positions | `b2bf27e893078189ce43236471c9a4b4293087bb` | Added typed live batched-position support and collision-safe routing |
| Provisioning Phase 1 | `b924659ea41a60b6b11e8432142b0b0073fe083d` | Added provisioning foundations and authoritative runtime status semantics |
| Provisioning Phase 2A | Uncommitted at this snapshot | Adds closed-gate orchestration, strict contracts, secret safety, ACK/reboot/reconnect verification, and public readiness state |
| Firmware `2.7.34` | Audited, not certified | Provides source contracts but retains two truthfulness/persistence blockers |
| Final firmware certification | Pending | Enables selection of the real SDK minimum and physical E2E |

## 34. Next actions

1. Review this canonical document and commit SDK Phase 2A with it.
2. Joan completes the `0x20` persistence/idempotency fix.
3. Joan completes the truthful `0x24` COMMIT fix.
4. Bump the firmware version after both corrections.
5. Run the focused firmware microaudit.
6. Set the SDK certified minimum firmware to the audited version.
7. Review and commit that small SDK certification patch.
8. Run the physical TAG E2E and recovery matrix.
9. Integrate and validate the demo against the committed SDK revision.
10. Integrate and validate the commercial app against the committed SDK revision.

## 35. Source map

The current implementation is authoritative when this document and source
diverge. Primary references:

| Concern | Source |
| --- | --- |
| Public readiness API/models | `packages/eixam_connect_core/lib/src/entities/device_ready.dart`; `packages/eixam_connect_core/lib/src/interfaces/eixam_connect_sdk.dart` |
| Coordinator, firmware gate, reboot, final verification | `packages/eixam_connect_flutter/lib/src/provisioning/device_provisioning_coordinator.dart` |
| SoftSIM layout, encoders, CRC | `packages/eixam_connect_flutter/lib/src/provisioning/softsim_provisioning.dart` |
| SoftSIM transport/REJECT observer | `packages/eixam_connect_flutter/lib/src/provisioning/softsim_transport.dart` |
| ACK parser/coordinator | `packages/eixam_connect_flutter/lib/src/provisioning/provisioning_command_result.dart` |
| RF parsing/encoding | `packages/eixam_connect_flutter/lib/src/provisioning/strict_device_provisioning_config.dart` |
| Runtime status parser | `packages/eixam_connect_flutter/lib/src/device/eixam_device_runtime_status_packet.dart` |
| BLE routing | `packages/eixam_connect_flutter/lib/src/device/ble_device_runtime_provider.dart` |
| Secret command diagnostics | `packages/eixam_connect_flutter/lib/src/device/eixam_ble_command.dart` |
| SDK production wiring | `packages/eixam_connect_flutter/lib/src/sdk/eixam_connect_sdk_impl.dart` |
| Existing BLE contract | `packages/eixam_connect_flutter/BLE_DEVICE_CONTRACT.md` |
| Firmware commands/status/SoftSIM | `eixam-firmware/firmware/src/modules/Eixam/EixamConfig.h`; `eixam-firmware/firmware/src/modules/Eixam/EixamBLEBridge.cpp` |
| Firmware RF plan | `eixam-firmware/firmware/src/modules/Eixam/EixamRegionPlanTable.h`; `eixam-firmware/firmware/src/modules/Eixam/EixamRfPlan.cpp` |
| Firmware PRIMARY PSK application | `eixam-firmware/firmware/src/modules/Eixam/EixamChannelCrypto.cpp`; `eixam-firmware/firmware/src/modules/Modules.cpp` |
| Backend PSK endpoint | `eixam-platform/api/services/networkpsk/` |
| Backend RF endpoint | `eixam-platform/api/services/deviceconfigs/` |
