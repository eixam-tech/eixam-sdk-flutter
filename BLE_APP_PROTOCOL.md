# Eixam BLE — Protocol device ↔ app (backend)

Referència del que **envia el dispositiu cap a l’app** (notifications) i del que **rep de l’app** (provinent del backend o de l’usuari). Per preparar la integració a l’app.

---

## Serveis i característiques BLE

| UUID (característica) | Nom | Direcció | Descripció |
|-----------------------|-----|----------|------------|
| `6ba1b218-15a8-461f-9fa8-5dcae273ea00` | Service | — | Servei Eixam |
| `6ba1b218-15a8-461f-9fa8-5dcae273ea01` | **TEL** | Device → App (Notify) | Telemetria: posició 10B |
| `6ba1b218-15a8-461f-9fa8-5dcae273ea02` | **SOS** | Device → App (Notify) | Alertes SOS: paquet 10B (o 5B) |
| `6ba1b218-15a8-461f-9fa8-5dcae273ea03` | **INET** | App → Device (Write) | Comandes curtes (1–4 bytes) |
| `6ba1b218-15a8-461f-9fa8-5dcae273ea04` | **CMD** | App → Device (Write) | Comandes (1–16 bytes) |

- **TEL** i **SOS**: l’app ha de subscriure’s a **Notify**; el dispositiu envia quan hi ha dades (cua interna, màx 20 bytes per notificació).
- **INET** i **CMD**: l’app escriu; ambdues criden el mateix handler de comandes. INET té `maxLen` 4, CMD 16 (per payloads com SOS_ACK_RELAY).

---

## 1. Device → App (notifications)

### 1.1 TEL (telemetria) — característica TEL

**Quan:** El dispositiu envia la seva posició periòdicament (interval TEL, p. ex. 120 s) i durant el compte enrere SOS. També pot rebre posicions d’altres nodes per LoRa i reenviar-les per BLE (si s’implementa).

**Format:** sempre **10 bytes** (paquet de posició Eixam).

| Byte | Camp | Tipus | Descripció |
|------|------|--------|------------|
| 0–1 | nodeId | uint16 LE | Node ID del dispositiu (origen) |
| 2–7 | lat, lon, alt | packed | Lat (20b), Lon (21b), Alt (7b, unitats de 40 m). Formules: lat = (latEnc×180/1048576)−90; lon = (lonEnc×360/2097152)−180; alt = (altEnc)×40 m |
| 8–9 | meta | uint16 LE | speed(4) + heading(4) + batt(2) + gpsQuality(2) + packetId(4). speed/heading 0–15; batt 0–3 (crític/baix/mitjà/ok); gpsQuality 0–3 (no fix/2D/3D/DGPS); packetId 0–15 (rotació) |

**Decodificació ràpida (pseudocodi):**
- `nodeId = bytes[0] | (bytes[1] << 8)`
- Lat/Lon/Alt: mateix packing que SOS 10B (veure apartat SOS més avall). B2–B7 idèntics.
- Meta: `batt = (bytes[8]>>6)&0x03`, `gpsQuality = (bytes[8]>>4)&0x03`, `packetId = bytes[8]&0x0F` (bytes[9] per speed/heading si cal).

**Font al firmware:** `EixamPositionCodec::encode` / `decode`, `EixamTelModule::sendPosition` → `sendTelNotify`.

---

### 1.2 SOS — característica SOS

**Quan:** (1) El dispositiu és **origen** d’un SOS i envia el seu paquet SOS (countdown o actiu). (2) El dispositiu és **relay** i rep un SOS per LoRa i el reenvia a l’app (perquè l’app el passi al backend).

**Format:** **10 bytes** (amb posició) o **5 bytes** (sense posició).

**10 bytes (SOS amb posició):**

| Byte | Camp | Tipus | Descripció |
|------|------|--------|------------|
| 0–1 | nodeId | uint16 LE | **Origen** de l’SOS (qui ha premut SOS) |
| 2–7 | lat, lon, alt | packed | Mateix format que TEL (lat 20b, lon 21b, alt 7b) |
| 8–9 | flags | uint16 LE | sosType(2) + retryCount(2) + relayCount(2) + battLevel(2) + gpsQuality(2) + speedEst(2) + packetId(4). **sosType != 0** → és un paquet SOS |

**5 bytes (SOS mínim, sense posició):**  
B0–B1 nodeId, B2–B3 flags (16b), B4 seq.

**Com saber si és SOS:**  
Si el paquet ve per la característica **SOS**, sempre és un esdeveniment SOS. Si es rep el mateix format 10B per **TEL**, es pot comprovar `flags.sosType != 0` (bits 15–14 del word flags = byte 9 high nibble).

**Font al firmware:** `EixamSOSPacket::encodeFull` / `decode`, `EixamSOSModule::sendSOSViaBLE` i relay → `sendSOSNotify`.

---

## 2. App → Device (comandes, provinents de backend o usuari)

Totes les comandes es reben per **escriptura** a la característica **INET** (ea03) o **CMD** (ea04). El primer byte és sempre el **opcode**; els següents són el payload (si n’hi ha).

### 2.1 Resum de comandes

| Opcode | Nom | Payload | Descripció |
|--------|-----|---------|------------|
| `0x01` | INET_OK | — | App/backend té connexió a internet. Dispositivu deixa d’enviar TEL per LoRa (només BLE). |
| `0x02` | INET_LOST | — | App ha perdut internet. Dispositiu torna a enviar TEL per LoRa. |
| `0x03` | POS_CONFIRMED | — | Backend ha rebut/confirmat la posició. Es guarda per a SOS mínim (5B) sense posició. |
| `0x04` | SOS_CANCEL | — | Cancel·lar SOS (countdown) o resoldre SOS actiu/reconegut. |
| `0x05` | SOS_CONFIRM | — | Confirmar SOS durant el compte enrere (com si passés el temps). |
| `0x06` | SOS_TRIGGER_APP | — | Disparar SOS des de l’app (com HOLD 3s → compte enrere 20s). |
| `0x07` | SOS_ACK | — | Backend ha reconegut l’SOS; el dispositiu para el to d’alerta. |
| `0x08` | SOS_ACK_RELAY | nodeId (2 bytes, LE) | En un **relay**: el backend ha ackat l’SOS d’origen `nodeId`; el relay envia Rescue ACK per LoRa a aquest node. |
| `0x10` | SHUTDOWN | — | Apagar el dispositiu (només des de l’app). |
| `0x20` | PROVISION | (futur) | Provisioning config (no implementat). |

### 2.2 Format dels payloads

- **1 byte:** `[ 0xXX ]` — la majoria de comandes.
- **0x08 SOS_ACK_RELAY:** `[ 0x08, nodeId_lo, nodeId_hi ]` (3 bytes). `nodeId = data[1] | (data[2] << 8)`.

L’app ha d’enviar com a mínim 1 byte (l’opcode). Les comandes amb payload exigeixen la longitud adequada (per 0x08, len >= 3).

---

## 3. Flux típics per a l’app

1. **Connexió BLE**  
   - Subscriure’s a **TEL** i **SOS** (Notify).  
   - En connectar, indicar estat d’internet: escriure **INET_OK** (0x01) o **INET_LOST** (0x02) segons connexió backend.

2. **Recepció de posicions (TEL)**  
   - Cada notificació de **TEL** són 10 bytes; decodificar amb el format de posició Eixam (nodeId, lat, lon, alt, meta).  
   - Enviar al backend si hi ha internet; si el backend confirma posició, enviar **POS_CONFIRMED** (0x03) al dispositiu.

3. **Recepció d’SOS (SOS)**  
   - Cada notificació de **SOS** són 10 bytes (o 5); nodeId = origen de l’SOS.  
   - Enviar l’SOS al backend. Quan el backend reconegui l’SOS:  
     - Si aquest dispositiu és l’**origen** → enviar **SOS_ACK** (0x07).  
     - Si aquest dispositiu és un **relay** (has rebut un SOS d’un altre node) → enviar **SOS_ACK_RELAY** (0x08) amb el nodeId de l’origen (2 bytes, little-endian).

4. **Disparar / cancel·lar SOS des de l’app**  
   - Disparar: **SOS_TRIGGER_APP** (0x06).  
   - Cancel·lar compte enrere o resoldre: **SOS_CANCEL** (0x04).

---

## 4. Feedback de so al dispositiu

El dispositiu reprodueix tons per buzzer en aquests moments (resum; detall a `01_SPRINT1_TEL_BLE_SOS.md`):

- **Activar SOS** (botó 3 s o app 0x06): escala pujant Do–Mi–Sol–Si.
- **Compte enrere 20 s**: bip cada 1 s (recordatori).
- **SOS actiu**: to tipus ambulància (alta/baixa) cada 1 s fins ACK.
- **Cancel·lar / resoldre SOS** (botó o app 0x04): escala baixant Si–Sol–Mi–Do.
- **Apagada** (app 0x10): to descendent del sistema.

---

## 5. Documents i codi de referència

- **Constants i UUIDs:** `firmware/src/modules/Eixam/EixamConfig.h`
- **Formats 10B posició:** `EixamPositionCodec.cpp` (encode/decode)
- **Formats SOS 5B/10B:** `EixamSOSPacket.cpp` (encode/decode)
- **Handler de comandes:** `EixamBLEBridge::onCmdReceived` a `EixamBLEBridge.cpp`
- **Platform BLE (NRF52):** `src/platform/nrf52/NRF52Bluetooth.cpp` (setup Eixam service, Notify TEL/SOS, Write INET/CMD)
- **Tons i SOS:** `01_SPRINT1_TEL_BLE_SOS.md` (secció «Estat actual del Sprint 1»)

Aquest document reflecta l’estat actual del firmware (Sprint 1); extensions (provisioning, més comandes) es documentaran quan s’implementin.
