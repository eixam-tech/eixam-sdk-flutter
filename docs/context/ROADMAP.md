# EIXAM FIRMWARE — Roadmap i Checklist

## Timeline

```
Setmana 1-2:  SPRINT 1 — Posició 10B + BLE DynGW + SOS
              → Demo: SOS funcional amb botó, dual-route, app rep posicions
              
Setmana 3-4:  SPRINT 2 — Heartbeat + Scoring + Clustering
              → Demo: Clusters automàtics, POLL/REPORT, DynGW offload

Setmana 5-6:  SPRINT 3 — SF adaptatiu + Rescue fase 1 + Smart sampling
              → Demo: Producte complet per pilot Baqueira

Setmana 7+:   SPRINT 4 — Tuning de consum (GPS power policy + LIS2DH real)
              → Demo: autonomia millorada i política GPS validada al maquinari
```

## Checklist per Sprint

### SPRINT 1 ✦ Setmanes 1-2
**Codi base:** completat (WisMesh Tag / `rak_wismeshtag` + `-DEIXAM_CLIENT`). **Tests de validació:** encara checklist més avall.

- [x] Crear `src/modules/Eixam/` directory
- [x] `EixamConfig.h` — constants i UUIDs (ports 258–261, canals SOS/TEL, BLE, cluster…)
- [x] `EixamPositionCodec.h/.cpp` — encode/decode 10B
- [x] `EixamTelModule.h/.cpp` — telemetria Eixam (interval configurable; port `EIXAM_TEL_APP`)
- [x] `EixamBLEBridge.h/.cpp` — BLE Notify (TEL/SOS/INET/CMD), cues, fragments `0xD0`
- [x] `EixamSOSPacket.h/.cpp` — encode/decode 5B/10B
- [x] `EixamFibonacciRetry.h/.cpp` — timer Fibonacci
- [x] `EixamSOSModule.h/.cpp` — state machine SOS
- [x] Modificar `portnums.pb.h` — 4 portnums Eixam (258–261)
- [x] Modificar `main.cpp` / `Modules.cpp` — registrar mòduls, globals
- [x] Modificar `PositionModule.cpp` — desactivar en mode Eixam (quan aplica)
- [x] Variant + build: `rak_wismeshtag` (o equivalent) + `-DEIXAM_CLIENT=1`
- [ ] TEST: Posicions 10B volant entre 2 dispositius
- [ ] TEST: BLE Notify funcional, INET_OK suprimeix LoRa
- [ ] TEST: SOS pre-confirm + confirm + Fibonacci + dual-route
- [ ] TEST: SOS ACK redueix retries

### SPRINT 2 ✦ Setmanes 3-4

**Abans de codificar:** Llegir `06_SPRINT2_NVM_POSITIONS_COVERAGE.md` — definir què guardar, on i com; aprofitar-ho per **mapejar cobertura** durant excursions.

- [x] **NVM + config:** `EixamNVM` — implementar `saveConfig`/`loadConfig` (LittleFS `/eixam/config.bin`), `EixamDeviceConfig` persistent *(febrer 2026: Opció A doc + codi)*
- [x] **Posicions locals:** Guardar paràmetres TEL (posició GPS + hora) de forma local (fitxer/buffer rotatiu a LittleFS) → `/eixam/tel_positions.bin`, `EixamTelPositionLog`
- [x] **Rangetest / cobertura:** Guardar posició pròpia + posicions rebudes dels veïns amb la senyal que tenim cap a ells (SNR/RSSI) — per mapar cobertura en excursions (veure `05_RANGETEST_COVERAGE_LOG.md` i `06_SPRINT2_NVM_POSITIONS_COVERAGE.md`) — millores opció A (WISMESH_TAG): `time_unix`, payload 60s amb posició, descàrrega RANGETEST per streaming
- [x] `EixamScoring.h` / `.cpp` — càlcul score 8 bits (+ `LOG_DEBUG` des de `EixamTelModule` fins que arribi Heartbeat)
- [x] `EixamHeartbeat.h/.cpp` — heartbeat 30s, taula veïns, cleanup *(registrat a `Modules.cpp`; wire 8B port 260; `memberCount` TX pendent EixamCluster)*
- [x] `EixamCluster.h/.cpp` — FREE/MEMBER/AGGREGATOR, POLL/REPORT, agregat MVP *(detall pendent: `08_SPRINT2_CLUSTER_PENDING.md`)*
- [x] Modificar `EixamTelModule` — `setClusterSuppressLoRaTel` (MEMBER/AGG)
- [x] **Estalvi MEMBER — fase 1 (tancada):** `eixam/` + guard BLE (`isPhoneConnected`): `runOnce` MEMBER **5 s** sense app / **1 s** amb app; `EixamGpsCyclic` opt-in (defecte off, veure `08`). **Fase 2 (posterior):** duty-cycle BLE advertising, sleep SX126x entre POLLs, `PowerFSM` només si cal.
- [ ] **NodeDB / `NodeInfoLite` (camps Eixam)** — *Diferit* fins que app/backend necessitin estat Eixam al NodeDB; **no** és requisit per tancar el pilot Sprint 2 al camp.
- [ ] TEST: Heartbeats a <200m, no a >300m
- [ ] TEST: Scoring correcte (INET_OK = 128+)
- [ ] TEST: Cluster formation automàtica en <120s
- [ ] TEST: POLL/REPORT cicle funcional
- [ ] TEST: Paquet agregat conté N posicions
- [ ] TEST: INET node pren aggregador
- [ ] TEST: Member sleep <2mA
- [ ] TEST: Split quan membre s'allunya

**Pilot Sprint 2 al camp (feb. 2026):** el **codi** del sprint (cluster, scoring, agregat, INET/BLE, 2 dBm intra-cluster, estalvi MEMBER fase 1) es considera **llest per provar**. Queden els **TEST:** de sobre (validació) i, si cal, repetir proves Sprint 1.

### SPRINT 3 ✦ Setmanes 5-6
- [x] `EixamSFAdapter.h` — SF adaptatiu per veïns (header; lògica `calculateSF`)
- [x] Integrar SF adapter a `EixamTelModule` + `SX126xInterface::eixamApplyMeshSpreadingFactor` (mesh SF 7–11)
- [x] `EixamRescue.h/.cpp` — fase 1 integrada (port 261 separat; REQUEST_POS/ACK_SOS/BUZZER/STATUS)
- [x] Integrar handlers CMD Rescue (port 261) fora de `EixamSOSModule` (delegació a `EixamRescue`)
- [x] Smart position (mostreig GPS adaptatiu per velocitat derivada + persistència local)
- [x] Log local TEL en **rolling buffer 64KB** (`/eixam/tel_positions.bin`) per sync diferit
- [x] **TEL (258) a potència mínima en context cluster** — `EixamIntraClusterTx`: TX **propis** port **258** amb payload **agregat `0xC2`** i `isClusterSuppressLoRaTel()` → 2 dBm (mateixa cua que 260).
- [x] **TEL RX → BLE cap a l’app** — `EixamTelModule::handleReceived`: **10 B** veí, `sendTelNotify`, rate-limit, només si **BLE connectat** (`EIXAM_CLIENT`).
- [ ] TEST: SF canvia amb nombre de veïns
- [ ] TEST: REQUEST_POS → resposta amb posició
- [ ] TEST: ACK_SOS → LED verd + slow retries
- [ ] TEST: BUZZER activat remotament
- [ ] TEST: Smart sampling (walk/run/bike/very-fast) + persistència local 64KB sense pèrdua global
- [ ] TEST: Sync backlog (BLE) amb ingest backend idempotent

### SPRINT 4 ✦ Tuning de consum (Setmana 7+)
- [ ] Definir pressupost d'autonomia objectiu (perfil: caminada, trail, esquí) i mètriques de consum
- [ ] `EixamGpsPolicy.h/.cpp` — política GPS per activitat (quiet/moviment) amb estats explícits
- [ ] Integrar lectura real LIS2DH a `EixamHardware` (`isMovementDetected()`, `lastActivityMs()`)
- [ ] Integrar `EixamGpsPolicy` a `Modules.cpp` i `EixamTelModule` (sense regressió SOS/Rescue)
- [ ] Definir constants de política a `EixamConfig.h` (temps quiet, mínim ON, hysteresis moviment)
- [ ] Validar coexistència amb `EixamGpsCyclic` (fallback MEMBER sense app)
- [ ] Estratègia fail-safe: en dubte de sensor, prioritzar GPS ON en SOS/Rescue
- [ ] TEST: corrent mitjà en repòs i en moviment (comparativa S3 vs S4)
- [ ] TEST: temps de reacquisició fix (TTFF) després de període quiet
- [ ] TEST: no pèrdua de telemetria crítica en transicions ON/OFF GPS
- [ ] TEST: SOS/Rescue mantenen prioritat i latència acceptable amb política activa

## Fitxers finals

```
src/modules/Eixam/          (12+ fitxers nous; creix amb Sprint 3)
├── EixamConfig.h           
├── EixamPositionCodec.h/cpp    Sprint 1
├── EixamTelModule.h/cpp        Sprint 1 → modificat Sprint 2+3
├── EixamBLEBridge.h/cpp        Sprint 1
├── EixamSOSPacket.h/cpp        Sprint 1
├── EixamFibonacciRetry.h       Sprint 1
├── EixamSOSModule.h/cpp        Sprint 1 → modificat Sprint 3
├── EixamScoring.h/cpp          Sprint 2
├── EixamHeartbeat.h/cpp        Sprint 2 ✓
├── EixamCluster.h/cpp          Sprint 2 ✓ (MVP)
├── EixamSFAdapter.h            Sprint 3
├── EixamRescue.h/cpp           Sprint 3 (fase 1)
├── EixamGpsPolicy.h/cpp        Sprint 4 (tuning consum)
└── EixamRoute.h/cpp            Diferit (backend/app)

Fitxers Meshtastic modificats:  (6 fitxers, canvis mínims)
├── portnums.pb.h               +4 línies
├── PositionModule.cpp          +3 línies (#ifdef)
├── PhoneAPI.cpp/h              +BLE characteristic
├── NodeDB.cpp/h                +camps Eixam (Sprint 2)
├── PowerFSM.cpp                +sleep state (Sprint 2)
└── main.cpp                    +registre mòduls + globals
```

## Docs per Cursor

```
docs/eixam/
├── 00_CONTEXT.md                         ← Carregar SEMPRE primer
├── 01_SPRINT1_TEL_BLE_SOS.md             ← Codi complet Sprint 1
├── 02_SPRINT2_HEARTBEAT_CLUSTER.md       ← Codi complet Sprint 2
├── 03_SPRINT3_SF_RESCUE_ROUTE.md         ← Codi complet Sprint 3
├── 04_ROADMAP.md                         ← Aquest fitxer
├── 05_RANGETEST_COVERAGE_LOG.md          ← Rangetest + log local (CSV)
├── 06_SPRINT2_NVM_POSITIONS_COVERAGE.md  ← Recordatori Sprint 2: què guardar, com, mapar cobertura
├── 07_BLE_APP_PROTOCOL.md                ← Device→App (TEL/SOS Notify) i App→Device (CMD) per integrar app/backend
├── 08_SPRINT2_CLUSTER_PENDING.md         ← Cluster: MVP vs pendent + estratègia power MEMBER / BLE
├── 09_BACKEND_APP_HANDOFF.md             ← Handoff backend (+ context app)
├── 10_SPRINT1_2_CONSOLIDATED.md          ← Resum línia base després Sprint 1+2
├── 11_TEAM_HANDOFF_INDEX.md              ← Índex per companys: app BLE vs backend
├── 12_SPRINT3_BRIEFING.md                ← Briefing executiu Sprint 3 (abans del 03 detallat)
├── 13_BLE_BACKLOG_SYNC_PROTOCOL.md       ← Sync diferit BLE (app/backend)
├── 14_BACKEND_INGEST_UNIFIED_CONTRACT.md ← Contracte únic backend: MQTT + BLE backlog
├── 15_BACKEND_ONE_PAGER.md               ← Backend quick-start (2 minuts)
├── 16_GUIDED_RESCUE_PHASE1.md            ← Guiatge rescat fase 1 (sense canvis SF/canal)
├── 17_APP_HANDOFF_FINAL.md               ← Handoff final APP (scope tancat)
└── 18_BACKEND_HANDOFF_FINAL.md           ← Handoff final BACKEND (scope tancat)
```

## Com usar amb Cursor

1. Obre el repo Meshtastic firmware al Cursor
2. Carrega `00_CONTEXT.md` com a context del projecte
3. Obre el document del sprint que toca (01, 02, 03)
4. Demana a Cursor que implementi pas a pas
5. Compila i testeja després de cada pas
6. Marca els checkboxes d'aquest document

## Licensing

- Firmware: GPL-3.0 (repo públic `eixam-technologies/eixam-firmware`)
- Backend/App/Hardware: Propietari (repos privats)
- Model: Com Prusa, Arduino — firmware obert, valor al ecosistema complet
