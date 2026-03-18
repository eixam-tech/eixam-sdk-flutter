# Eixam firmware – Changelog

## [2.7.21] – Sprint 1 (2025-02)

### SOS i relay
- **Canal SOS (869.525 SF12)**: només el dispositiu que activa l’SOS l’usa (directe a cim/gateway).
- **Canal TEL per SOS**: l’origen envia SOS per mesh amb port TEL_APP i `sosType=1`; els relays reenvien sempre per TEL (no per canal SOS).
- **Relay**: si té BLE+inet envia l’SOS a l’app; si no, reenvia per TEL amb `hop_limit` decrementat (màx 3 salts). No es reenvia si `hop_limit <= 1`.
- **Evitar loop**: el node que ha fet l’SOS ignora el seu propi paquet si li torna per broadcast (no el re-forward).
- **Reiniciar SOS**: HOLD 3 s en estat ACTIVE/ACK inicia compte enrere nou; BLE 0x04 (SOS_CANCEL) també resol un SOS actiu.

### Relay: ACK del backend i notificació
- Quan un relay envia l’SOS al backend per BLE, queda en estat “pending ACK”.
- L’app envia **0x08 + nodeId** (origen) per indicar “backend ha ackat”; el relay envia **Rescue ACK** (port EIXAM_RESCUE_APP, cmd 0x02) al node origen.
- **Timeout 60 s**: si no arriba ACK, el relay reenvia l’SOS per TEL.

### Tons (buzzer WisMesh Tag)
- **Activar SOS (botó 3 s)**: escala pujant Do–Mi–Sol–Si als 3 s (no abans, per evitar reflex de deixar anar).
- **Activar SOS des de l’app (0x06)**: mateixa escala pujant.
- **Compte enrere 20 s**: bip recordatori cada **1 s** (440 Hz, 150 ms).
- **SOS actiu**: to tipus ambulància (880 Hz / 660 Hz), cicle **cada 1 s** (500 ms alta, 500 ms baixa). Fins ACK o cancel·lar.
- **Cancel·lar / resoldre SOS** (botó o app 0x04): escala **baixant** Si–Sol–Mi–Do (mateix so que activació al revés).
- **Apagada (BLE 0x10)**: to descendent del sistema (`playShutdownMelody`).

### BLE
- **Cua d’enviament** cap a l’app (TEL/SOS): fins a 4 paquets per tipus; drenatge cada 100 ms.
- **Comandes CMD**: 0x01 INET_OK, 0x02 INET_LOST, 0x03 POS_CONFIRMED, 0x04 SOS_CANCEL, 0x05 SOS_CONFIRM, 0x06 SOS_TRIGGER_APP, 0x07 SOS_ACK, 0x08 SOS_ACK_RELAY (+ nodeId), 0x10 SHUTDOWN.
- **Protocol device ↔ app**: `docs/eixam/07_BLE_APP_PROTOCOL.md`.

### Build
- Variant: `rak_wismeshtag` (WisMesh Tag, nRF52840). Buzzer: PIN_BUZZER 21.
