# Guided Rescue — Fase 1 (sense canvi de SF/canal)

Objectiu: guiatge de rescat **post-SOS confirmat** sense tocar la configuracio global LoRa.

La fase 1 utilitza:

- port `EIXAM_RESCUE_APP` (261) per comandes de rescat
- TEL/SOS existents per enviar posicio i estat
- app del rescatador per calcular distancia/rumb (GPS dual)

---

## 1) Flux operatiu (resum)

1. Backend rep SOS i el marca actiu.
2. Rescatador entra en mode "Guided Rescue" a l'app.
3. App/rescat envia comandes Rescue al node victima.
4. Victima envia posicio/estat amb els canals ja existents.
5. App mostra fletxa + distancia ("bola de drac").
6. En proximitat, backend/app activa `BUZZER_ON`.

---

## 2) Comandes Rescue (port 261)

Payload base: `[targetId_lo, targetId_hi, rescueId_lo, rescueId_hi, cmd, param?]`

| Cmd | Nom | Efecte a la victima (MVP Fase 1) |
|-----|-----|----------------------------------|
| `0x01` | `REQUEST_POS` | Forca `sendPosition()` immediat |
| `0x02` | `ACK_SOS` | Marca SOS com ACK (`onACKReceived`) |
| `0x03` | `BUZZER_ON` | Activa to SOS per localitzacio |
| `0x04` | `BUZZER_OFF` | Atura to SOS |
| `0x05` | `STATUS_REQ` | Respon amb `STATUS_RESP` (`0x85`) al port 261 + push SOS/TEL |

### `STATUS_RESP` (`0x85`) payload (10 bytes, port 261)

`[rescueId(2), victimId(2), 0x85, state, batt2b, gpsQ2b, retryCount, flags]`

- `state`: `EixamSOSState` (0..4)
- `batt2b`: bateria codificada Eixam (0..3)
- `gpsQ2b`: qualitat GPS (0..3)
- `retryCount`: contador actual retries SOS
- `flags`:
  - bit0: relay pending ACK
  - bit1: `INET` disponible al node

Constants a `EixamConfig.h`:

- `EIXAM_RESCUE_CMD_REQUEST_POS`
- `EIXAM_RESCUE_CMD_ACK_SOS`
- `EIXAM_RESCUE_CMD_BUZZER_ON`
- `EIXAM_RESCUE_CMD_BUZZER_OFF`
- `EIXAM_RESCUE_CMD_STATUS_REQ`

---

## 3) Guia app rescuer (UX)

- Poll de posicio: cada 5-10 s (`REQUEST_POS`) si no hi ha stream suficient.
- Calcul:
  - distancia (haversine)
  - rumb des de rescatador a victima
  - fletxa direccional en pantalla
- Regla proximitat suggerida:
  - `<120 m` -> `BUZZER_ON`
  - `<40 m` -> vibracio/alerta visual forta
  - objectiu localitzat -> `BUZZER_OFF`

---

## 4) Què **no** fa aquesta fase

- No canvia SF ni canal LoRa global.
- No crea "link dedicat" fora de la mesh.
- `EixamRescue` separa el port 261 i delega al SOS/TEL/HW (fase 1). Queda pendent la versio completa (8 comandes + mode RESCUE avançat).

---

## 5) Relacio amb Sprint 3

Fase 1 desbloqueja valor real de rescat amb risc baix.

Fase 2 (futur): mode RF dedicat de proximitat i/o handover avançat amb tuning dinamic.

