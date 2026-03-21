# Eixam BLE - Protocol device <-> app (backend)

This document is the BLE source of truth for the current device <-> app behavior.

## BLE Services And Characteristics

| UUID | Name | Direction | Notes |
|------|------|-----------|-------|
| `6ba1b218-15a8-461f-9fa8-5dcae273ea00` | Service | - | EIXAM service |
| `6ba1b218-15a8-461f-9fa8-5dcae273ea01` | TEL | Device -> App notify | Telemetry packets, always 10 bytes |
| `6ba1b218-15a8-461f-9fa8-5dcae273ea02` | SOS | Device -> App notify | SOS packets, 10 or 5 bytes |
| `6ba1b218-15a8-461f-9fa8-5dcae273ea03` | INET | App -> Device write | Short commands, 1-4 bytes |
| `6ba1b218-15a8-461f-9fa8-5dcae273ea04` | CMD | App -> Device write | Commands up to 16 bytes |

## Device -> App Packets

### TEL

- Always 10 bytes.
- `nodeId` is `uint16 LE`.
- Bytes `2..7` encode lat/lon/alt.
- Bytes `8..9` contain telemetry metadata including battery, GPS quality, and packet id.

### SOS

- Either 10 bytes with position or 5 bytes without position.
- `nodeId` is `uint16 LE`.
- 10-byte packets reuse the same packed position shape as TEL.
- SOS flags include `sosType`, `retryCount`, `relayCount`, `batteryLevel`, `gpsQuality`, `speedEst`, and `packetId`.
- Any packet arriving on the SOS characteristic must be treated as an SOS event.

## App -> Device Commands

| Opcode | Name | Payload |
|--------|------|---------|
| `0x01` | INET_OK | none |
| `0x02` | INET_LOST | none |
| `0x03` | POS_CONFIRMED | none |
| `0x04` | SOS_CANCEL | none |
| `0x05` | SOS_CONFIRM | none |
| `0x06` | SOS_TRIGGER_APP | none |
| `0x07` | SOS_ACK | none |
| `0x08` | SOS_ACK_RELAY | `nodeId` as 2-byte little-endian |
| `0x10` | SHUTDOWN | none |
| `0x20` | PROVISION | future |

## Runtime Expectations

1. Connect and discover services before validating compatibility.
2. Subscribe to TEL and SOS notifications after connection.
3. Decode TEL and SOS centrally in the SDK/device layer.
4. Keep UI free from raw byte construction and packet parsing.
5. Use `POS_CONFIRMED`, `SOS_ACK`, and `SOS_ACK_RELAY` only as backend-driven responses.
