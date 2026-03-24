# EIXAM SDK — Quality Gates

## Propòsit

Aquest document defineix els mínims de qualitat per considerar un canvi acceptable dins del monorepo EIXAM.

L’objectiu no és burocràcia.  
L’objectiu és protegir el SDK com a producte reusable i evitar regressions.

---

## 1. Principi general

El criteri principal no és “tenir més codi”.  
El criteri principal és:

- més fiabilitat
- més reusabilitat
- menys regressions
- menys dependència de l’app host

Atès que EIXAM és SDK-first, la qualitat s’ha de mesurar sobretot sobre el SDK. 

---

## 2. Gate mínim per qualsevol canvi rellevant

Abans de considerar un canvi com a acceptable, ha de complir com a mínim:

- `dart format --set-exit-if-changed .`
- `flutter analyze`
- `flutter test`

Si algun d’aquests falla, el canvi no està llest.

---

## 3. Gate mínim de producte-SDK

A més del gate tècnic bàsic, qualsevol canvi del SDK ha de preservar:

- API pública coherent
- contractes previs no trencats sense justificació
- estat observable estable
- comportament defensiu davant errors
- separació clara entre SDK i host app

---

## 4. Gate d’arquitectura

Un canvi no ha de:

- moure lògica crítica del SDK cap a l’app
- duplicar lògica de negoci en widgets
- exposar dades massa crues si es poden encapsular millor
- augmentar acoblament innecessari entre packages

La direcció correcta és:
- nucli fort al SDK
- host app prima
- components reutilitzables al package UI. 

---

## 5. Gate de testing per capes

### 5.1 Canvis a `eixam_connect_core`
Han d’anar preferentment acompanyats de:
- unit tests
- tests de state machine
- tests de use cases
- tests de contracte públic quan apliqui

### 5.2 Canvis a `eixam_connect_flutter`
Han d’anar preferentment acompanyats de:
- tests de repositories/adapters
- tests de persistència
- tests de comportament observable
- fakes o in-memory implementations quan sigui viable

### 5.3 Canvis a `eixam_connect_ui`
Han d’anar preferentment acompanyats de:
- widget tests dels components reutilitzables
- tests d’estats crítics (`loading`, `enabled`, `disabled`, `error`)

### 5.4 Canvis a `apps/eixam_control_app`
No requereixen cobertura massiva per defecte.  
Són suficients:
- smoke tests bàsics
- proves manuals de flux
- cap lògica crítica nova a la UI

Això és coherent amb el fet que la demo app és un host de validació, no el producte final. :contentReference[oaicite:15]{index=15}

---

## 6. Quality gate funcional per àrees clau

## 6.1 SOS
Per considerar SOS prou sòlid, cal:

- trigger funciona
- cancel funciona
- estat observable coherent
- persistència/restauració si aplica
- tests de transicions principals
- la UI no assumeix lògica crítica fora del SDK

SOS és un pilar central del MVP. :contentReference[oaicite:16]{index=16}

## 6.2 Tracking
Per considerar Tracking prou sòlid, cal:

- start/stop correctes
- stream d’estat coherent
- stream de posició coherent
- gestió de stale positioning
- persistència/restauració si aplica
- contractes públics consistents

## 6.3 Death Man
Per considerar Death Man prou sòlid, cal:

- programació correcta
- confirmació/cancel·lació correctes
- finestra de gràcia coherent
- escalat correcte segons estat
- tests de transicions principals

## 6.4 Emergency Contacts
Per considerar Contactes prou sòlid, cal:

- llistar
- afegir
- actualitzar
- activar/desactivar
- eliminar
- persistència coherent

El comportament pertany al SDK; la UX no. 

## 6.5 Device / BLE readiness
Per considerar Device prou sòlid, cal:

- estat observable coherent
- lifecycle clar
- comportament defensiu
- no dependre de la pantalla per interpretar l’estat
- preparació per BLE real sense contractes trencadissos

---

## 7. Quality gate específic per APP/BLE integration

Per donar per vàlid el mínim d’integració app/BLE, han d’estar resolts o clarament contractats:

- parse TEL 10B
- parse SOS 5B/10B
- reassemblatge `0xD0`
- deduplicació TEL/SOS
- tolerància offline i reintents
- pipeline robust cap backend
- superfície SOS usable
- superfície Rescue fase 1 usable

Això surt directament del handoff final APP. :contentReference[oaicite:18]{index=18}

---

## 8. Quality gate específic per Guided Rescue Phase 1

No es considerarà prou llest si:

- la UI manipula bytes o protocol directament
- les accions de rescue no passen per una API clara del SDK
- l’estat de rescue no és observable de forma neta
- les regles bàsiques d’ús no estan cobertes

Per a la fase 1, el mínim funcional gira al voltant de:
- `REQUEST_POS`
- `ACK_SOS`
- `BUZZER_ON`
- `BUZZER_OFF`
- `STATUS_REQ`
- estat retornat via `STATUS_RESP`

La fase 1 no inclou canvi de SF/canal ni rescue avançat dedicat. 

---

## 9. Quality gate de documentació

Qualsevol canvi rellevant en arquitectura, contractes o fluxos ha d’actualitzar, si toca:

- `README.md` o document principal curt
- docs enfocats del package o feature
- aquest document si canvia el nivell mínim de qualitat
- `SDK_DECISIONS.md` si canvia una decisió de fons

Això evita que el coneixement es quedi només al codi. :contentReference[oaicite:20]{index=20}

---

## 10. Quality gate de release interna

Abans de considerar una fase “prou bona” per continuar construint-hi a sobre, jo exigiria:

- format ok
- analyze ok
- tests ok
- host app arrenca
- cap regressió funcional evident
- decisions i docs mínimament alineades
- cap lògica crítica colada a la UI

---

## 11. Regla final

No promovem un canvi perquè “funciona a la demo”.  
El promovem perquè:

- està ben encapsulat
- és testejable
- és reusable
- i és coherent amb l’estratègia SDK-first