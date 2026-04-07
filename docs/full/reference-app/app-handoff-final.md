# Eixam — APP Handoff Final (Sprint 3)

Decisio de scope tancada:

- `EixamRoute` **no** s'implementa al firmware.
- Rescue avancat (fase 2) **no** s'implementa al firmware.
- Seguiment de ruta, desviacions i workflow avancat de rescat van a **APP/BACKEND**.

---

## 1) Objectiu de l'app

- Pont entre dispositiu i backend.
- UX d'operacio (tracking, SOS, rescue).
- Orquestrar comandes cap al dispositiu segons decisio backend.

---

## 2) Quines dades rep l'app del dispositiu

### BLE Notify TEL

- Paquet de posicio Eixam de **10 bytes**.
- També pot rebre fragments `0xD0` (payload gran, p. ex. agregats); cal reassemblar.

### BLE Notify SOS

- SOS d'origen o relay (format 5B/10B segons cas).
- Esdeveniments SOS de control (`0xE1`, `0xE2`) segons protocol.

### Rescue status (fase 1)

- En resposta a `STATUS_REQ`, el dispositiu emet `STATUS_RESP` (`0x85`, port 261).
- Camps utiles per UI: `state`, bateria, qualitat GPS, retries, flags.

---

## 3) Quines comandes envia l'app al dispositiu

### INET/CMD BLE (operacio general)

- `INET_OK`, `INET_LOST`
- `POS_CONFIRMED`
- `SOS_CANCEL`, `SOS_CONFIRM`, `SOS_TRIGGER_APP`
- `SOS_ACK`, `SOS_ACK_RELAY`

### Rescue fase 1 (control de camp)

- `REQUEST_POS`
- `ACK_SOS`
- `BUZZER_ON`
- `BUZZER_OFF`
- `STATUS_REQ`

Nota: el dispositiu ja implementa aquestes primitives locals.

---

## 4) UX i logica que son de l'app/backend (no firmware)

- Seguiment de ruta i desviacions.
- Overdue i alertes contextuals.
- Flux operatiu de rescat (estats, prioritzacio, assignacio, accions guiades).
- Qualsevol logica de negoci de producte.

---

## 5) Requisits tecnics d'implementacio app

- Reassemblar fragments `0xD0` de TEL.
- Deduplicar TEL/SOS abans de pintar i abans d'enviar backend.
- Tolerancia offline: cua local i reintent.
- Integrar backlog sync BLE (quan apliqui) per pujada diferida.

---

## 6) Expectatives de comportament del firmware actual

- Mostreig GPS intern adaptatiu per velocitat.
- TX LoRa governat per interval/duty-cycle (no envia totes les mostres internes).
- Persistencia local TEL en rolling buffer (64KB) per no perdre historial recent.
- SOS amb retries/ACK/feedback local.
- Rescue fase 1 funcional.

---

## 7) Checklist minim APP per tancar integracio

- Parse TEL 10B i SOS 5B/10B.
- Reassemblatge `0xD0`.
- Pipeline API backend robust (idempotent).
- Pantalla SOS amb ACK backend -> comanda corresponent a dispositiu.
- Pantalla Rescue fase 1: `request pos`, `status`, `buzzer`, `ack`.
