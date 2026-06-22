# BLE Security Contract

Status: design/inventory pass for `SEC-BLE-1`, `SEC-BLE-2`, `SEC-BLE-3`, `SEC-BLE-4`, and `SEC-BLE-5`.

This document defines the required BLE security direction before runtime or firmware changes are implemented. It is intentionally not an implementation spec for a single release; it is the contract that SDK, native protection runtimes, and firmware must converge on.

## Scope

In scope:

- BLE command writes for SOS trigger, SOS cancel, shutdown, reboot, runtime status, volume, and relay ACK commands.
- BLE notification parsing for TEL, SOS, relay, and runtime status packets.
- Pairing semantics and device identity trust.
- SDK/public errors and migration behavior.

Out of scope for this pass:

- Backend protocol changes.
- MQTT cancel behavior.
- Firmware implementation.
- App behavior changes.

## Current Inventory

### Connection and Pairing

- `BleDeviceRuntimeProvider.pair(...)` currently validates only that `pairingCode.trim().length >= 4`; the code is not sent to the device and is not used cryptographically.
- Pairing scans, requires a selected scan result from `BleDebugRegistry`, connects via `RealBleClient.connect(...)`, checks EIXAM service compatibility, binds notifications, and reads runtime status.
- `RealBleClient.connect(...)` resolves a Flutter Blue Plus `BluetoothDevice`, calls `device.connect(...)`, waits for a stable connected state, discovers services, caches services, and registers a raw command writer.
- Android reconnect/protection paths check system bond presence with `FlutterBluePlus.bondedDevices` or `BluetoothAdapter.bondedDevices`, but current foreground writes do not prove that the active link is encrypted at write time.
- iOS reconnect/protection paths retrieve a CoreBluetooth peripheral by UUID and reconnect, but current code does not have an explicit SDK-level secure-link assertion before command writes.

### Service Discovery

The EIXAM GATT service and characteristics are defined in `EixamBleProtocol`:

- service: `6ba1b218-15a8-461f-9fa8-5dcae273ea00`
- TEL notify: `...ea01`
- SOS notify: `...ea02`
- INET write: `...ea03`
- CMD write: `...ea04`

`RealBleClient.isEixamCompatible(...)` requires TEL, SOS, and INET. CMD is optional for legacy compatibility.

Android native protection mode and iOS protection mode discover the same service and command characteristics and own BLE while protection mode is armed.

### Command Encoding and Writes

`EixamDeviceCommand` encodes commands as raw bytes:

- `0x01` INET OK
- `0x02` INET LOST
- `0x03` POS CONFIRMED
- `0x04` SOS CANCEL
- `0x05` SOS CONFIRM
- `0x06` SOS TRIGGER APP
- `0x07` SOS ACK
- `0x08 + nodeId` SOS ACK RELAY
- `0x10` SHUTDOWN
- `0x11 + volume` notification volume
- `0x12 + volume` SOS volume
- `0x22` REBOOT
- `0x23` GET DEVICE STATUS

Short commands use INET (`ea03`) when payload length is within `inetMaxPayloadLength`; forced or longer commands use CMD (`ea04`). `SOS CANCEL` may fall back from CMD to INET for compatibility. Android and iOS native protection command writers mirror this routing.

There is currently no nonce, counter, key identifier, MAC, signature, or authenticated device/session identity in command frames.

### Inbound Packet Classification

`BleDeviceRuntimeProvider` subscribes to TEL and SOS notifications and classifies packets through `BleIncomingPayloadClassifier` plus runtime-specific logic:

- runtime status packets update `_connectedBleTagNodeId`;
- TEL fragments are reassembled before classification;
- `0xD2` relay packets classify peer/self payloads;
- SOS packets are parsed by `EixamSosPacket`;
- SOS event packets are parsed by `EixamSosEventPacket`;
- own-vs-relay classification compares parsed plaintext `nodeId` to `_connectedBleTagNodeId`;
- if connected node identity is unknown, the SDK may request runtime status and reclassify.

Android native protection has a separate classifier in `ProtectionBleSosIdentityClassifier`. It prefers a strict connected node id, can use active BLE hardware metadata as a guardrail, and treats metadata-only node matches as insufficient identity proof. iOS protection currently records and deduplicates SOS snapshots from CoreBluetooth notifications but does not authenticate packet origin.

### Anti-Replay / Dedup

Dart runtime suppresses duplicate own-device SOS packets using `_recentSosPacketSignatures` with a 2 second exact-signature window: `nodeId:packetId/rawHex`.

Android native protection uses cycle keys and recent terminal suppression for lifecycle stability. iOS notification delivery uses snapshot/cycle notification dedupe. These are operational dedup mechanisms, not cryptographic replay protection.

## Security Enforcement Points

Security must be enforced at every layer that can accept, send, or interpret safety-relevant BLE data.

### SDK Dart Layer

Required responsibilities:

- classify commands by criticality;
- block critical writes when secure-link/session requirements are not met;
- build authenticated command frames once firmware supports them;
- validate inbound authenticated packet envelopes before own-vs-relay decisions;
- expose public errors and diagnostics without leaking secrets;
- preserve typed SDK APIs so host apps never send raw BLE command bytes.

Primary files:

- `packages/eixam_connect_flutter/lib/src/device/real_ble_client.dart`
- `packages/eixam_connect_flutter/lib/src/device/eixam_ble_command.dart`
- `packages/eixam_connect_flutter/lib/src/device/ble_device_runtime_provider.dart`
- `packages/eixam_connect_flutter/lib/src/device/ble_incoming_payload_classifier.dart`
- packet parsers under `lib/src/device`

### Android Native Layer

Required responsibilities:

- enforce the same critical-write policy in `ProtectionBleRuntimeOwner.sendCommand(...)` and queued writes;
- verify bond/secure link capability before protection-mode command writes where Android exposes usable state;
- support authenticated frame construction or receive already-framed bytes from Dart with a single source of truth;
- apply authenticated inbound identity rules before native lifecycle observation or relay handoff.

Primary files:

- `ProtectionBleRuntimeOwner.kt`
- `ProtectionBleSosIdentityClassifier.kt`
- `ProtectionBleSosNativeRouting.kt`
- `ProtectionRuntimeBridge.kt`

### iOS Native Layer

Required responsibilities:

- enforce the same critical-write policy in `sendProtectionCommand(...)`;
- use CoreBluetooth characteristic protection/pairing failures as hard failures for critical writes;
- avoid claiming own-device origin from unauthenticated notification bytes;
- support authenticated command frame construction or receive already-framed bytes from Dart with a single source of truth.

Primary files:

- `ProtectionRuntimeBridge.swift`

### Firmware / GATT

Required responsibilities:

- require authenticated encrypted pairing/bonding for critical write characteristics where platform BLE permits it;
- reject unauthenticated critical commands before parsing opcode side effects;
- implement pairing-code-backed device authentication and key derivation;
- maintain per-client replay counters/windows;
- authenticate device-origin and relay-origin packets, including node identity.

GATT permissions are necessary but not sufficient. Phase 3/4 cryptographic frames are still required because BLE link security varies by platform state, OS behavior, pairing mode, and relay transport.

## Command Criticality

Critical commands:

- `0x06` SOS TRIGGER APP
- `0x04` SOS CANCEL
- `0x10` SHUTDOWN
- `0x22` REBOOT

Sensitive operational commands:

- `0x05` SOS CONFIRM
- `0x07` SOS ACK
- `0x08` SOS ACK RELAY
- `0x11` notification volume
- `0x12` SOS volume

Read/status or low-risk commands:

- `0x01` INET OK
- `0x02` INET LOST
- `0x03` POS CONFIRMED
- `0x23` GET DEVICE STATUS

Phase 1 may treat only critical commands as hard-blocked on insecure links. Phase 3 should authenticate all commands, with critical commands requiring strict replay rejection.

## Staged Design

### Phase 0: Fail-Safe Checks and Documentation

No firmware breakage.

- Add capability/diagnostic inventory only: firmware security capability unknown, legacy command frame, secure-link unknown.
- Centralize command criticality in SDK design before changing write behavior.
- Ensure all command writers are known: Dart `RealBleClient`, Android native protection, iOS native protection.
- Ensure logs identify whether a command used legacy raw bytes or future secure frames.
- Do not trust plaintext `nodeId` as authenticated identity; keep current conservative guardrails and document that classification remains unauthenticated.

### Phase 1: Require Secure/Bonded Link Where Platform Supports It

Firmware-compatible, but behavior-changing.

- For critical writes, require platform evidence of an associated/bonded device before command write.
- Android: require bonded device for reconnect/protection writes and add write-time guard in Dart/native paths. Treat `bondRequired`, `pairingRequired`, and `insufficientAuthentication` as `E_BLE_LINK_NOT_SECURE` or `E_BLE_PAIRING_REQUIRED`.
- iOS: rely on GATT characteristic protection once firmware marks critical characteristics as encryption/authentication required. Surface CoreBluetooth write/authentication failures as public SDK errors.
- If the platform cannot prove encryption but firmware has not advertised secure command capability, use compatibility policy below.

### Phase 2: Real Pairing/Auth Handshake

Requires firmware changes.

- Pairing code becomes proof material, not a UI-only length check.
- SDK connects to an unpaired/provisioning mode and sends a pairing handshake over a dedicated secure-control characteristic or command opcode.
- Device and SDK perform authenticated key agreement using the pairing code as a passcode/PAKE input or as an out-of-band verifier.
- Result is a per-device secret stored in mobile secure storage and device nonvolatile storage.
- SDK records a key id, device id, firmware security capability, and initial counter state.

### Phase 3: Authenticated Command Frame

Requires firmware changes.

- Raw critical opcodes are no longer accepted when firmware advertises secure command support.
- SDK wraps command opcodes in an authenticated frame with version, flags, opcode, counter/nonce, device/session id, payload, and auth tag.
- Firmware verifies frame version, target device/session, monotonic counter/replay window, command authorization, and MAC before executing side effects.
- Failed MAC/counter checks must not trigger command behavior.

### Phase 4: Authenticated Node Identity and Relay Integrity

Requires firmware/mesh protocol changes.

- Device-origin TEL/SOS/event packets include an authenticated origin proof.
- Relay packets authenticate both originator identity and relay/gateway identity, or carry nested origin-authenticated payloads plus relay-authenticated metadata.
- SDK classifies own-vs-relay only after authentication. Unauthenticated packets may be surfaced as diagnostics but must not drive own-device SOS lifecycle or backend relay handoff as trusted origin.

## Command Frame Proposal

Binary frame, little-endian numeric fields:

| Field | Size | Notes |
| --- | ---: | --- |
| magic | 1 | `0xA5`, separates secure frames from legacy raw opcodes |
| version | 1 | initial value `0x01` |
| flags | 1 | bit 0 critical, bit 1 response requested, bit 2 relay-related |
| opcode | 1 | existing command opcode |
| keyId | 1 | active per-device key slot |
| sessionId | 4 | random session id negotiated at connect/auth time |
| counter | 8 | strictly monotonic per key/session sender counter |
| deviceIdHash | 8 | truncated hash of canonical device identity or firmware immutable id |
| payloadLen | 1 | payload bytes after opcode-specific header |
| payload | N | command-specific payload |
| authTag | 16 | truncated HMAC-SHA-256 or AES-CMAC over all preceding fields plus protocol context |

Replay rules:

- Firmware stores highest accepted counter per bonded client/key and rejects counters less than or equal to the stored value.
- If session counters are used, session establishment must be authenticated and must bind session id to the key.
- A small out-of-order receive window is allowed only if commands can be reordered safely; critical commands should use strict monotonic acceptance.
- Counter reset requires key rotation, explicit re-pair, or firmware factory reset.
- SDK treats replay rejection as `E_BLE_REPLAY_REJECTED`.

MAC input context:

- include service UUID, characteristic UUID, firmware security protocol version, command criticality, and negotiated session id;
- never MAC only the payload;
- never reuse the same key for command frames and relay/origin packet frames without domain separation labels.

## Pairing Proposal

The pairing code must become an authentication secret or verifier.

Recommended model:

- Device displays, prints, or ships with a short pairing code that is rate-limited and scoped to the device.
- SDK and firmware run a PAKE-style exchange if feasible. If firmware constraints make PAKE impractical, use the pairing code as an input to derive a verifier during a one-time provisioning exchange over an already encrypted BLE link.
- The result is a high-entropy per-device root key `K_device`, never the raw pairing code.
- Derive keys with domain separation:
  - `K_cmd = HKDF(K_device, "eixam-ble-command-v1")`
  - `K_notify = HKDF(K_device, "eixam-ble-notify-v1")`
  - `K_relay = HKDF(K_device, "eixam-ble-relay-v1")`
- Store SDK keys in platform secure storage/keychain. Store firmware keys in protected nonvolatile storage where available.

Rotation/reset:

- User unpair removes mobile key material and system bond.
- Firmware factory reset removes bonded clients and `K_device`.
- Key rotation creates a new key id and invalidates old counters after successful confirmation.
- Device replacement must require a fresh pairing code exchange; do not transfer keys based only on backend device id or plaintext `nodeId`.
- Forgotten bond with retained SDK key should be recoverable only through a secure rebind flow that proves possession of both the device and pairing code.

## Public Errors and States

Add public errors as `DeviceException`/SDK-visible failures with stable codes:

- `E_BLE_LINK_NOT_SECURE`: current BLE link cannot prove required encryption/authentication for the requested operation.
- `E_BLE_PAIRING_REQUIRED`: secure pairing/auth handshake has not completed, key material is missing, or the system bond was forgotten.
- `E_BLE_COMMAND_AUTH_FAILED`: firmware rejected a command frame auth tag or SDK detected an inbound auth failure.
- `E_BLE_REPLAY_REJECTED`: firmware or SDK rejected a stale/replayed counter, nonce, or packet id.
- `E_BLE_DEVICE_ID_UNVERIFIED`: SDK cannot verify that plaintext `nodeId`/device id belongs to the connected device or relay origin.

Diagnostic states should distinguish:

- `legacyRawCommand`
- `secureLinkUnknown`
- `secureLinkRequired`
- `secureSessionMissing`
- `secureFrameReady`
- `firmwareSecurityCapabilityUnknown`
- `firmwareSecurityCapabilityLegacy`
- `firmwareSecurityCapabilityV1`

## Compatibility and Migration

Compatibility must be explicit and capability-driven.

- Legacy firmware may continue to allow scan, connect, service discovery, battery/firmware reads, runtime status reads, and non-critical diagnostics.
- Legacy firmware should not silently receive critical commands once the SDK has a secure-command enforcement flag enabled.
- During migration, critical commands on legacy firmware should either:
  - be blocked with `E_BLE_PAIRING_REQUIRED` / `E_BLE_LINK_NOT_SECURE`, or
  - be allowed only behind an explicit temporary compatibility flag with clear diagnostics.
- Firmware must advertise a security capability version through runtime status, device information, or a dedicated characteristic before SDK enables secure frames.
- SDK rollout:
  1. ship diagnostics and capability detection;
  2. ship secure-link gates for supported platforms/firmware;
  3. ship pairing handshake behind capability detection;
  4. require secure frames for firmware capability v1+;
  5. remove compatibility flag after field migration.

Suggested capability values:

- `0`: legacy raw command protocol;
- `1`: secure-link required for critical GATT writes;
- `2`: authenticated pairing/session supported;
- `3`: authenticated command frames required;
- `4`: authenticated notification/relay origin supported.

## Required Firmware Changes

- Add GATT permissions requiring encryption/authentication for critical write paths where possible.
- Add a security capability version readable by SDK/native runtimes.
- Implement pairing/auth handshake that uses the pairing code cryptographically.
- Store per-device/per-client secret material and key ids.
- Verify authenticated command frames before executing opcodes.
- Maintain replay counters/windows across reconnects and power cycles.
- Return explicit auth/replay/pairing errors where GATT/protocol allows.
- Add authenticated origin data to TEL/SOS/event packets.
- Add authenticated relay packet integrity, including originator and relay identity.
- Reject legacy critical raw opcodes when secure command capability is enabled.

## Required SDK Changes

- Centralize command criticality and secure-command policy.
- Add secure capability model to runtime status/diagnostics.
- Add write-time secure-link/session checks in:
  - Dart `RealBleClient.writeDeviceCommand(...)`;
  - Android `ProtectionBleRuntimeOwner.sendCommand(...)` / `startCommandWrite(...)`;
  - iOS `ProtectionRuntimeBridge.sendProtectionCommand(...)`.
- Replace raw command encoding with versioned secure frame encoding when capability requires it.
- Store/retrieve pairing key material from platform secure storage.
- Map native and firmware auth failures to public SDK errors.
- Authenticate inbound packets before own-vs-relay classification when capability supports it.
- Treat unauthenticated identity as unverified and prevent it from driving local device lifecycle where strict identity is required.
- Add tests before enabling behavior changes.

## Test Plan Before Implementation

Unit tests:

- command write blocked on insecure/unbonded link for critical opcodes;
- non-critical legacy operations remain allowed under legacy capability policy;
- pairing code is used in key derivation/handshake and invalid code fails;
- replayed command counter is rejected;
- wrong MAC/auth tag is rejected;
- stale counter is rejected after reconnect;
- raw critical opcode rejected when firmware capability requires secure frames;
- spoofed `nodeId` does not classify as own device without authenticated identity;
- relay packet requires authenticated origin where capability says relay auth is supported;
- `E_BLE_DEVICE_ID_UNVERIFIED` is surfaced for identity-dependent decisions without proof;
- Android native protection command writer applies same critical gate as Dart;
- iOS native protection command writer applies same critical gate as Dart.

Integration/manual release tests:

- Android bonded secure-link critical write succeeds on secure-capable firmware;
- Android forgotten bond returns `E_BLE_PAIRING_REQUIRED`;
- iOS protected characteristic prompts/pairs as expected and fails closed when unavailable;
- firmware rejects wrong MAC without executing SOS cancel, shutdown, or reboot;
- firmware rejects replay after app reinstall/reconnect according to counter reset policy;
- legacy firmware migration path matches configured compatibility flag.

## Open Design Decisions

- Exact cryptographic primitive must be selected with firmware constraints known. HMAC-SHA-256 truncated to 16 bytes is the default recommendation unless firmware already has AES-CMAC hardware/library support.
- Pairing should prefer PAKE. If not feasible, document the weaker fallback and require BLE encrypted link plus rate limiting.
- The immutable device identity used in `deviceIdHash` must be defined by firmware. BLE MAC/random address alone is not sufficient on all platforms.
- Decide whether secure frame construction lives entirely in Dart and native receives framed bytes, or whether native protection runtimes share a small framing implementation. One source of test vectors is mandatory either way.
