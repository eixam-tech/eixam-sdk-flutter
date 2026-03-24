# Eixam BLE Backlog Sync Protocol (app + backend)

Protocol operatiu per pujar **telemetria diferida** (backlog local del tag) cap al backend quan hi ha connexio BLE estable.

Objectiu: garantir el cas "he acabat l'excursio i ho pujo tot" sense dependre del LoRa en temps real.

---

## 1) Model de dades i identitat d'event

Cada posicio logada al tag es tracta com un event idempotent:

- `nodeId16`
- `timeUnix` (segons `EixamTelPositionLog`, 32 bits)
- `wire10` (payload TEL 10 B original)

**EventId recomanat (app/backend):**

`eventId = nodeId16 + ":" + timeUnix + ":" + packetId`

on `packetId` surt del nibble baix de meta (byte 8 de `wire10`).

El backend ha de fer **dedup** per `eventId`.

---

## 2) Flux alt nivell

1. App connecta per BLE i envia `INET_OK` (`0x01`) si te sortida backend.
2. App demana inici de sync backlog.
3. Tag envia paquets de dades backlog en blocs.
4. App puja cada bloc al backend.
5. Backend confirma offset/events persistits.
6. App envia ACK de bloc al tag.
7. Tag marca avanc i segueix fins "END".

Si es talla la connexio, el sync continua des de l'ultim offset ACK.

---

## 3) Transport BLE proposat (sobre caracteristica CMD)

Com que `CMD` admet fins 16 bytes per write, fem protocol curt amb opcodes nous.

### 3.1 App -> Device (write CMD)

| Opcode | Nom | Payload | Notes |
|---|---|---|---|
| `0x30` | `BACKLOG_SYNC_START` | `sinceUnix` (u32 LE, opcional `0`), `maxEvents` (u16 LE) | Inicia sessio de sync |
| `0x31` | `BACKLOG_SYNC_ACK` | `sessionId` (u8), `nextOffset` (u32 LE) | ACK del darrer bloc rebut i persistit |
| `0x32` | `BACKLOG_SYNC_ABORT` | `sessionId` (u8), `reason` (u8) | Abort controlat |
| `0x33` | `BACKLOG_SYNC_STATUS_REQ` | `sessionId` (u8) | Demana estat resumit |

### 3.2 Device -> App (notify TEL, framing 0xD1)

Per reutilitzar la cua TEL i evitar afegir una caracteristica nova.

`TEL notify`:

- Byte 0: `0xD1` (framing backlog)
- Byte 1: `msgType`
- Byte 2: `sessionId`
- Byte 3..: payload tipus

`msgType`:

| Type | Nom | Payload |
|---|---|---|
| `0x01` | `SYNC_META` | `totalEvents` (u16), `startOffset` (u32), `endOffset` (u32) |
| `0x02` | `SYNC_CHUNK` | `chunkOffset` (u32), `count` (u8), `records...` |
| `0x03` | `SYNC_END` | `sentEvents` (u16), `lastOffset` (u32), `status` (u8) |
| `0x04` | `SYNC_ERROR` | `code` (u8), `detail` (u8) |

`record` dins `SYNC_CHUNK`:

- `timeUnix` u32 LE
- `wire10` (10 bytes)

Record size: 14 bytes.

---

## 4) Paginacio i mida de bloc

Per no saturar BLE:

- recomanat `count = 1` per notify (14 B + capcalera)
- opcional `count = 2` si MTU/stack ho permet estable

La progressio va per `offset` del log local (`/eixam/tel_positions.bin`).

---

## 5) Garanties i reintents

- El tag no avanca "confirmat" fins rebre `BACKLOG_SYNC_ACK`.
- L'app no ACKa fins que backend ha persistit.
- Timeout de sessio recomanat: 30 s sense trafic -> abort suau.
- Reconnect: tornar a `BACKLOG_SYNC_START` amb `sinceUnix` i backend dedup.

---

## 6) Backend API suggerida

Endpoint exemple:

`POST /api/eixam/backlog/batch`

Body:

- `deviceNodeId`
- `sessionId`
- `records[]` (`timeUnix`, `wire10`, `eventId`)
- `source` (`ble-phone`, `ble-cim`)

Resposta:

- `acceptedCount`
- `duplicateCount`
- `highestCommittedOffset` (opcional, si l'app el fa servir)

---

## 7) Integracio amb mode cluster/LoRa

- Aquest protocol cobreix el cas **diferit** (final excursio o punt CIM/refugi).
- LoRa TEL continua com best-effort en temps real.
- Si hi ha BLE+INET, prioritzar backlog sync sobre flood LoRa no critic.

---

## 8) MVP definitiu (ready-to-implement)

Aquest document es considera **MVP definitiu de protocol** per repartir feina entre firmware, app i backend.

### 8.1 Firmware (tag)

- Implementar opcodes `0x30..0x33` a `CMD`.
- Afegir framing `0xD1` a TEL notify (`SYNC_META`, `SYNC_CHUNK`, `SYNC_END`, `SYNC_ERROR`).
- Iterar `EixamTelPositionLog` per `offset` i emetre chunks.
- Persistir punt de progrés de sessió (com a mínim en RAM; opcional NVM si es vol reprendre després reboot).

### 8.2 App

- Gestionar sessió (`START` -> chunks -> `ACK` -> `END`).
- No fer `ACK` al tag fins que backend confirmi persistència.
- Reintents i timeout de sessió (30 s recomanat).
- Dedup local opcional (el dedup fort és al backend amb `eventId`).

### 8.3 Backend

- Endpoint batch idempotent (`eventId` únic).
- Retorn `acceptedCount` / `duplicateCount` i, opcionalment, `highestCommittedOffset`.
- Monitoratge de latència de pujada i percentatge de duplicats.

---

## 9) Compatibilitat

- No trenca `07_BLE_APP_PROTOCOL.md` actual.
- `0xD1` es nou framing TEL (separat de `0xD0` agregat cluster).
- Si app no implementa backlog sync, el sistema segueix funcionant com fins ara.

---

## 10) Canvi de versió del protocol

Per evitar ambigüitats, es recomana incloure un byte `protoVer` dins `SYNC_META` (v1 actual).

