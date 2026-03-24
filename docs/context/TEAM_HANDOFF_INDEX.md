# Eixam — Índex per l’equip (resum + qui llegeix què)

Un sol lloc per **compartir amb companys**: què està llest al firmware i **quins documents** han de llegir el **desenvolupador d’app (BLE)** i el **desenvolupador de backend**.

---

## 1. Què tenim apunt (línia base firmware, febrer 2026)

Resum; el detall està a **`10_SPRINT1_2_CONSOLIDATED.md`** i la checklist a **`04_ROADMAP.md`**.

| Tema | Estat |
|------|--------|
| **TEL 10 B** (codec, LoRa port 258) | Fet |
| **SOS** (LoRa 259 + BLE, Fibonacci, botó Eixam) | Fet |
| **BLE Eixam** (servei propi: TEL / SOS notify, INET+CMD write, cues, fragments `0xD0`) | Fet |
| **Cluster** (port 260: heartbeat 8 B, POLL/REPORT, agregat `0xC2`) | Fet (MVP) |
| **INET_OK** → suprimeix TEL LoRa; dades cap a app per BLE | Fet |
| **Agregat cluster** → BLE amb `0xD0` si INET + connectat | Fet |
| **NVM Eixam** (`/eixam/config.bin`: PSK, URL, interval TEL…) | Fet (separat de config Meshtastic) |
| **Log posicions locals** + rangetest / cobertura (docs `05` / `06`) | Fet |
| **2 dBm LoRa** en tràfis **propis** port **260** (cluster) | Fet |
| **Validació camp** (tests `04`) | Pendent |
| **TEL RX LoRa → BLE** (veïns / familiars) | Fet (Sprint 3) |
| **TEL 258 a baixa potència en cluster** | Fet (Sprint 3) |
| **Smart sampling GPS** (walk/run/bike/very-fast) + log local rolling 64KB | Fet (Sprint 3) |
| **Route / Rescue avançat (fase 2)** | Diferit a backend/app |

**Versió:** veure `version.properties` + `APP_VERSION` després del build; entorn típic **`rak_wismeshtag`** amb **`EIXAM_CLIENT`**.

---

## 2. Document per al company que fa l’**app** (BLE)

**Paquet final APP (obligatori):**
- [`17_APP_HANDOFF_FINAL.md`](17_APP_HANDOFF_FINAL.md) — handoff final i scope tancat
- [`07_BLE_APP_PROTOCOL.md`](07_BLE_APP_PROTOCOL.md) — protocol BLE detallat
- [`13_BLE_BACKLOG_SYNC_PROTOCOL.md`](13_BLE_BACKLOG_SYNC_PROTOCOL.md) — sync diferit backlog
- [`16_GUIDED_RESCUE_PHASE1.md`](16_GUIDED_RESCUE_PHASE1.md) — rescue fase 1 (primitives)

Inclou:

- UUIDs del servei Eixam i característiques (**TEL**, **SOS**, **INET**, **CMD**).
- Format **10 B** posició (TEL) i SOS (5 B / 10 B).
- Comandes **INET** (`0x01` INET_OK, `0x02` INET_LOST, …) i **CMD**.
- Cua de notifies, fragments **`0xD0`** per blobs grans (agregat `0xC2`).
- Potència BLE al Tag (`NRF52_BLE_TX_POWER`).

**Context compartit (opcional):**
- [`11_TEAM_HANDOFF_INDEX.md`](11_TEAM_HANDOFF_INDEX.md)
- [`12_SPRINT3_BRIEFING.md`](12_SPRINT3_BRIEFING.md)

**No és el protocol Eixam:** l’app **Meshtastic** oficial usa **Protobuf / ToRadio / FromRadio** sobre el servei estàndard; el vostre producte Eixam es basa en el servei **`6ba1b218-…`** del `07`. Si integreu les dues coses, calen **dues piles BLE** clares.

---

## 3. Document per al company que fa el **backend**

**Paquet final BACKEND (obligatori):**
- [`18_BACKEND_HANDOFF_FINAL.md`](18_BACKEND_HANDOFF_FINAL.md) — handoff final i scope tancat
- [`15_BACKEND_ONE_PAGER.md`](15_BACKEND_ONE_PAGER.md) — resum ràpid operatiu
- [`14_BACKEND_INGEST_UNIFIED_CONTRACT.md`](14_BACKEND_INGEST_UNIFIED_CONTRACT.md) — contracte únic ingest
- [`13_BLE_BACKLOG_SYNC_PROTOCOL.md`](13_BLE_BACKLOG_SYNC_PROTOCOL.md) — ingest diferit via app BLE
- [`09_BACKEND_APP_HANDOFF.md`](09_BACKEND_APP_HANDOFF.md) — detall ports/wire històric i context

Inclou:

- Diferència **dades per BLE (app)** vs **dades per LoRa / gateway**.
- Ports **258** (TEL + agregat) i **260** (cluster).
- Estructura **heartbeat**, **POLL**, **REPORT**, agregat **`0xC2`**.
- **NodeId 16 vs 32 bits**.
- Rangetest / CSV (`05`).
- **§9** NodeDB Eixam *diferit*.
- Checklist ràpid per ingest API (múltiples posicions, `clusterId`, etc.).

**Complements:**
- [`04_ROADMAP.md`](04_ROADMAP.md) — estat sprint/tests
- [`12_SPRINT3_BRIEFING.md`](12_SPRINT3_BRIEFING.md) — resum executiu

---

## 4. Altres documents útils (tota l’equip)

| Fitxer | Per a què |
|--------|-----------|
| `00_CONTEXT.md` | Context del fork i regles (`src/modules/Eixam/`) |
| `04_ROADMAP.md` | Sprints, tests, pilot Sprint 2 |
| `08_SPRINT2_CLUSTER_PENDING.md` | Cluster: què està fet vs fase 2 power |
| `10_SPRINT1_2_CONSOLIDATED.md` | Resum tècnic S1+2 |
| `12_SPRINT3_BRIEFING.md` | **Briefing Sprint 3** (objectius, línies de treball, app/backend) |
| `13_BLE_BACKLOG_SYNC_PROTOCOL.md` | Protocol **MVP definitiu** de sync diferit BLE (app/backend) |
| `14_BACKEND_INGEST_UNIFIED_CONTRACT.md` | Contracte únic backend (MQTT + BLE backlog, dedup) |
| `15_BACKEND_ONE_PAGER.md` | Resum backend en 2 minuts (10 punts clau) |
| `16_GUIDED_RESCUE_PHASE1.md` | Guiatge rescat fase 1 (REQUEST_POS + BUZZER proximitat) |
| `03_SPRINT3_SF_RESCUE_ROUTE.md` | Codi / pseudocodi detallat Sprint 3 |
| `05_RANGETEST_COVERAGE_LOG.md` / `06_…` | Logs cobertura al dispositiu |

---

*Podeu enviar aquest fitxer (`11_TEAM_HANDOFF_INDEX.md`) com a missatge introductori i adjuntar o enllaçar `07` i `09` segons el rol.*
