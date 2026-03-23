# Eixam BLE — Protocol device ↔ app (backend)

Referència del que **envia el dispositiu cap a l’app** (notifications) i del que **rep de l’app** (provinent del backend o de l’usuari). Per preparar la integració a l’app.

**Índex per l’equip (qui llegeix què):** `11_TEAM_HANDOFF_INDEX.md`.

---

## Serveis i característiques BLE

| UUID (característica) | Nom | Direcció | Descripció |
|-----------------------|-----|----------|------------|
| `6ba1b218-15a8-461f-9fa8-5dcae273ea00` | Service | — | Servei Eixam |
| `6ba1b218-15a8-461f-9fa8-5dcae273ea01` | **TEL** | Device → App (Notify) | Telemetria: posició 10B |
| `6ba1b218-15a8-461f-9fa8-5dcae273ea02` | **SOS** | Device → App (Notify) | Alertes SOS: paquet 10B (o 5B) |
| `6ba1b218-15a8-461f-9fa8-5dcae273ea03` | **INET** | App → Device (Write) | Comandes curtes (1–4 bytes) |
| `6ba1b218-15a8-461f-9fa8-5dcae273ea04` | **CMD** | App → Device (Write) | Comandes (1–16 bytes) |

- **TEL** i **SOS**: l’app ha de subscriure’s a **Notify**; el dispositiu envia quan hi ha dades (cua interna FIFO per no bloquejar el mesh; veieu §6).
- **Màx. 20 bytes** per notificació (excepte reassemblatge `0xD0` en múltiples notificacions).
- **INET** i **CMD**: l’app escriu; ambdues criden el mateix handler de comandes. INET té `maxLen` 4, CMD 16 (per payloads com SOS_ACK_RELAY).

**Potència RF BLE (WisMesh Tag + Eixam):** es fixa **`NRF52_BLE_TX_POWER`** a `variants/nrf52840/rak_wismeshtag/variant.h` (**-4 dBm** per defecte), assumint mòbil a **~1–2 m**; redueix consum respecte al màxim del nRF52. Per gamificació / abast major, pujar a `0` o `4` (valors vàlids: vegeu `VALID_BLE_TX_POWER` a `NRF52Bluetooth.cpp`).

---

## Sprint 2 — Cluster i impacte a l’app (BLE)

Resum del que el firmware fa des del **Sprint 2** i que l’app ha de tenir en compte (detall mesh: `08_SPRINT2_CLUSTER_PENDING.md`, `09_BACKEND_APP_HANDOFF.md`).

| Tema | Comportament rellevant per BLE |
|------|--------------------------------|
| **INET_OK / INET_LOST** | Amb **INET_OK**, el tag pot **deixar d’enviar TEL LoRa individual** si és **MEMBER** o **AGGREGATOR** del cluster; les dades cap al backend passen preferentment per **BLE** (TEL 10 B i/o agregat). Amb **INET_LOST** torna el patró TEL per LoRa quan toqui. |
| **Agregat cluster `0xC2`** | El blob agregat (mateix wire que port **258** LoRa) pot arribar a l’app per **notify TEL** si hi ha **INET_OK** i **BLE connectat** (vegeu fragments `0xD0` més avall i §1.1). |
| **SOS** | **No** queda suprimit pel cluster: SOS segueix **LoRa** (canal dedicat + canal TEL amb flag) i **BLE** segons §1.2. |
| **MEMBER sense app** | El firmware pot anar més lent en cicles de cluster (`runOnce` ~5 s sense telèfon vs ~1 s amb app) per estalvi; amb app connectada es prioritza resposta BLE. |
| **GPS cíclic (opt-in)** | Constant `EIXAM_GPS_CYCLIC_MEMBER_ENABLE` (defecte **0**): només MEMBER sense BLE; **no** canvia el wire BLE, però pot afectar freqüència de fixes que veieu a TEL. |

### Format notify **fragments `0xD0`** (característica **TEL**, payload > 20 B)

Quan el blob (p. ex. agregat `0xC2…`) supera **20 bytes**, el dispositiu envia **múltiples notificacions TEL**. Cada fragment:

| Byte(s) | Camp | Descripció |
|---------|------|------------|
| 0 | `0xD0` | `EIXAM_BLE_TEL_AGG_FRAG` — marca fragmentació |
| 1–2 | totalLen | `uint16` **little-endian** — mida total del blob reassemblat |
| 3–4 | offset | `uint16` **little-endian** — offset d’aquest fragment dins del blob |
| 5–19 | payload | Fins a **15 bytes** de dades del blob (últim fragment pot ser més curt) |

L’app ha de **reassemblar** tots els fragments (mateix `totalLen`, `offset` creixent) fins a `offset + len_fragment == totalLen`. El resultat és idèntic al paquet **LoRa** (vegeu `09` §4).

---

## 1. Device → App (notifications)

### 1.1 TEL (telemetria) — característica TEL

**Quan:** El dispositiu envia la seva posició periòdicament (interval TEL, p. ex. 120 s) i durant el compte enrere SOS. **Reenviament de TEL d’altres nodes (LoRa → BLE)** està planejat **Sprint 3** (`03_SPRINT3_…`, `04_ROADMAP.md`); encara no al firmware actual.

**Format (cas clàssic):** **10 bytes** (paquet de posició Eixam).

> **Cluster:** Els agregats (`0xC2`, mida variable) arriben per **LoRa** (port 258) o, si el tag té **INET_OK** i BLE connectat, per **TEL notify** en fragments amb capçalera **`0xD0`** (totalLen, offset, dades). Després de reassemblar, el blob és el mateix que `0xC2`… Veieu `09_BACKEND_APP_HANDOFF.md` §4.

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

**Quan:** (1) El dispositiu és **origen** d’un SOS i envia el seu paquet SOS (countdown o actiu). (2) El dispositiu és **relay** i rep un SOS per LoRa i el reenvia a l’app (perquè l’app el passi al backend). (3) L’usuari ha **desactivat l’SOS amb el botó** (mantenir 3 s + to descendent): notificació d’esdeveniment (veure més avall).

#### Notify SOS per BLE — periodicitat (comportament actual del firmware)

A més del que ja arriba per **TEL** amb `sosType != 0` en alguns casos, el firmware envia **sempre** còpies explícites per la característica **SOS** (`sendSOSNotify`):

| Fase | Què envia per BLE **SOS** (i context TEL) |
|------|-------------------------------------------|
| **Compte enrere (pre-SOS, 20 s)** — **primers ~2 s** | A cada cicle del mòdul SOS (~**500 ms**): **notify SOS** amb **10 bytes** (posició actual + flags SOS, `encodeFull`). En paral·lel, **TEL** amb flag SOS (`sendPosition`) perquè l’app rebi posició ràpida sense esperar el període TEL normal. |
| **Compte enrere** — **del segon 2 al 20** | **No** es tornen a disparar aquests enviaments BLE des d’aquest camí (només feedback sonor local). L’app ja hauria rebut les primeres notificacions; si cal posició contínua, dependrà del flux **TEL** habitual o de l’usuari que confirmi/cancel·li. |
| **SOS actiu / SOS reconegut (ACK)** | A cada reintents amb interval **Fibonacci** (junt amb TX LoRa SOS i TX pel canal TEL amb SOS): de nou **notify SOS** **10 B** (`encodeFull`) per mantenir el backend alineat mentre l’emergència és activa. |
| **Relay** | En rebre un SOS vàlid per mesh (origen ≠ propi node), es fa **notify SOS** amb el **mateix payload** rebut (5 B o 10 B) perquè l’app el reenviï al backend. |

**Nota:** Per a SOS **actiu**, el camí **LoRa** pot usar paquet **mínim 5 B** si hi ha **POS_CONFIRMED** (`0x03`); el camí **BLE** en `sendSOSViaBLE` usa **sempre 10 B amb posició** (GPS actual) per simplificar la integració a l’app.

**Format normal SOS:** **10 bytes** (amb posició) o **5 bytes** (sense posició).

**Format desactivació manual (device → app):** **4 bytes** — no és un paquet SOS mesh.

| Byte | Valor | Descripció |
|------|--------|-------------|
| 0 | `0xE1` | `EIXAM_BLE_SOS_EVT_DEACTIVATED` — esdeveniment “usuari ha desactivat SOS amb botó 3s” |
| 1 | `0x01` o `0x02` | `0x01` = cancel·lat durant **compte enrere** (pre-SOS). `0x02` = cancel·lat amb SOS **ja disparat** → l’app ha d’informar el backend. |
| 2–3 | nodeId | uint16 LE — node que ha desactivat |

**Format confirmació cancel·lació des de l’app (device → app):** **4 bytes** — resposta després d’un **Write** vàlid de `0x04` (SOS_CANCEL).

| Byte | Valor | Descripció |
|------|--------|-------------|
| 0 | `0xE2` | `EIXAM_BLE_SOS_EVT_APP_CANCEL_ACK` — el dispositiu ha aplicat la cancel·lació |
| 1 | `0x01` / `0x02` / `0x03` | Estat des del qual s’ha cancel·lat: **pre-SOS** (compte enrere), **SOS actiu**, **SOS reconegut** (ACK rebut, slow retries) |
| 2–3 | nodeId | uint16 LE |

Si l’estat no era cap d’aquests (p. ex. ja `INACTIVE`), el dispositiu **no** envia aquest paquet (el write 0x04 no té efecte).

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

**Font al firmware:** `EixamSOSPacket::encodeFull` / `decode`, `EixamSOSModule::sendSOSViaBLE`, `handleReceived` (relay) → `EixamBLEBridge::sendSOSNotify`; esdeveniments `0xE1` / `0xE2` → `notifyUserDeactivatedViaBLE` / `notifyAppCancelAck`.

---

## 2. App → Device (comandes, provinents de backend o usuari)

Totes les comandes es reben per **escriptura** a la característica **INET** (ea03) o **CMD** (ea04). El primer byte és sempre el **opcode**; els següents són el payload (si n’hi ha).

### 2.1 Resum de comandes

| Opcode | Nom | Payload | Descripció |
|--------|-----|---------|------------|
| `0x01` | INET_OK | — | App/backend té connexió a internet. Dispositivu deixa d’enviar TEL per LoRa (només BLE). |
| `0x02` | INET_LOST | — | App ha perdut internet. Dispositiu torna a enviar TEL per LoRa. |
| `0x03` | POS_CONFIRMED | — | Backend ha rebut/confirmat la posició. Es guarda per a SOS mínim (5B) sense posició. |
| `0x04` | SOS_CANCEL | — | Cancel·lar SOS (countdown) o resoldre SOS actiu/reconegut. El dispositiu respon amb **Notify** SOS `[0xE2, subcodi, nodeId]` si s’ha aplicat (veure §1.2). |
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
   - Avui cada notificació **BLE TEL** és 10 bytes; decodificar amb el format de posició Eixam (nodeId, lat, lon, alt, meta). (Si en el futur s’afegeix agregat per BLE, caldrà discriminar per opcode/longitud — veure `09_BACKEND_APP_HANDOFF.md`.)  
   - Enviar al backend si hi ha internet; si el backend confirma posició, enviar **POS_CONFIRMED** (0x03) al dispositiu.

3. **Recepció d’SOS (SOS)**  
   - Durant el **compte enrere**, els primers ~**2 s** poden arribar **moltes** notificacions **SOS** (10 B) i **TEL** amb flag SOS; tractar com a mateixa emergència (deduplicar per `nodeId` + finestra temporal si cal).  
   - En **SOS actiu**, les notificacions **SOS** segueixen el ritme de **reintents Fibonacci** (no cada segon fix).  
   - Cada notificació **SOS** és 10 bytes (o 5 en relay si el mesh envia mínim); nodeId = **origen** de l’SOS.  
   - Enviar l’SOS al backend. Quan el backend reconegui l’SOS:  
     - Si aquest dispositiu és l’**origen** → enviar **SOS_ACK** (0x07).  
     - Si aquest dispositiu és un **relay** (has rebut un SOS d’un altre node) → enviar **SOS_ACK_RELAY** (0x08) amb el nodeId de l’origen (2 bytes, little-endian).

4. **Disparar / cancel·lar SOS des de l’app**  
   - Disparar: **SOS_TRIGGER_APP** (0x06).  
   - Cancel·lar compte enrere o resoldre: **SOS_CANCEL** (0x04). Esperar **Notify** SOS `[0xE2, …]` per confirmar que el tag ha tornat a espera (o gestionar timeout si no arriba — estava ja INACTIVE).

---

## 4. Feedback de so al dispositiu

El dispositiu reprodueix tons per buzzer en aquests moments (resum; detall a `01_SPRINT1_TEL_BLE_SOS.md`):

- **Activar SOS** (botó 3 s o app 0x06): escala pujant Do–Mi–Sol–Si.
- **Compte enrere 20 s**: bip cada **1 s** (recordatori); vegeu §1.2 per enviaments BLE en els primers ~2 s.
- **SOS actiu**: to tipus ambulància (alta/baixa) cada 1 s fins ACK.
- **Cancel·lar / resoldre SOS**: botó **3 s** (mateix que activar) o app 0x04; escala baixant Si–Sol–Mi–Do. Si és botó amb SOS ja disparat, l’app rep notify `0xE1` + `0x02` a la característica SOS.
- **Apagada** (app 0x10): to descendent del sistema.

---

## 5. Documents i codi de referència

- **Constants i UUIDs:** `firmware/src/modules/Eixam/EixamConfig.h`
- **Formats 10B posició:** `EixamPositionCodec.cpp` (encode/decode)
- **Formats SOS 5B/10B:** `EixamSOSPacket.cpp` (encode/decode)
- **Handler de comandes:** `EixamBLEBridge::onCmdReceived` a `EixamBLEBridge.cpp`
- **Platform BLE (NRF52):** `src/platform/nrf52/NRF52Bluetooth.cpp` (setup Eixam service, Notify TEL/SOS, Write INET/CMD)
- **Tons i SOS:** `01_SPRINT1_TEL_BLE_SOS.md` (secció «Estat actual del Sprint 1»)

Aquest document reflecta l’estat **BLE** (**Sprint 1** + **Sprint 2** cluster, agregats `0xD0`, i **notify SOS** com a §1.2). Extensions (provisioning, més comandes, TEL veíns LoRa→BLE) es documentaran quan s’implementin. Per **backend / ports mesh 258–260**, veieu **`09_BACKEND_APP_HANDOFF.md`**.

---

## 6. Cua Eixam → app (notify)

El firmware **ja gestiona** una cua per no perdre notifies si el stack BLE està ocupat:

| Cua | Profunditat | Si s’omple |
|-----|-------------|------------|
| TEL (10 B i fragments d’agregat) | 8 entrades | Es descarta el **més antic** i s’enregistra `LOG_WARN`. |
| SOS | 8 entrades | Igual (prioritat de **drenatge**: primer es buida SOS, després TEL petit, després de completar un agregat fragmentat). |

- **Agregat gran (`0xD0`)**: mentre s’envien fragments, **no** s’encuen TEL petits nous al mateix flux de fragments; els 10 B van a la cua TEL. Un **segon** agregat gran mentre el primer encara fragmenta es **rebutja** (log).
- **App → dispositiu**: les escriptures a INET/CMD es processen al **callback** (sense cua al firmware). L’app hauria d’**eserialitzar** comandes crítiques (p. ex. no enviar 10 writes sense esperar si cal ordre estricte).

Implementació: `EixamBLEBridge.cpp` (`enqueueTel` / `enqueueSOS`, `drainQueues`).
