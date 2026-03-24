# EIXAM SDK — Decisions d’arquitectura i producte

## Propòsit

Aquest document recull les decisions actives que governen el disseny del SDK i de la Control App de referència.

No és un document de brainstorming.  
És una font curta de criteri per a desenvolupament, refactors, tests i integracions futures.

---

## 1. Principi rector

**EIXAM és SDK-first.**

El SDK és el nucli del producte.  
La Control App és una app host de validació i referència, no la UX final del producte.

Això implica que la lògica crítica no ha de viure a l’app, sinó al SDK. 

---

## 2. Repartiment de responsabilitats

### 2.1 Què pertany al SDK

El SDK ha de contenir, com a mínim:

- entitats i enums de domini
- interfícies i contractes públics
- use cases
- state machines
- lògica de SOS
- lògica de Tracking
- lògica de Death Man
- persistència i comportament de contactes d’emergència
- estat i contractes de dispositiu
- preparació per BLE/device integration
- preparació per realtime/backend integration

Això està alineat amb l’arquitectura validada i amb els pilars centrals del MVP. 

### 2.2 Què pertany a l’app host

L’app host ha de ser prima i limitar-se a:

- inicialitzar el SDK
- subscriure’s a streams i estats del SDK
- cridar APIs / use cases del SDK
- pintar UI
- oferir superfícies de validació operativa i tècnica

L’app no ha d’absorbir lògica de negoci ni lògica de protocol. 

---

## 3. Regla d’or de la UI

**La UI no interpreta protocol si això pot viure al SDK.**

Això inclou evitar a la capa app:

- parsing de paquets com a responsabilitat principal
- deduplicació
- reassemblatge de fragments
- state transitions de SOS / Rescue / Device
- orquestració de cues o reintents
- decisions de disponibilitat d’accions crítiques

La UI pot tenir helpers menors de format/render.  
La lògica crítica ha d’estar encapsulada al SDK. :contentReference[oaicite:4]{index=4}

---

## 4. Documents font de veritat per APP/BLE

Per a treball de l’app i integració BLE, els documents de referència són:

- `APP_HANDOFF_FINAL.md`
- `BLE_APP_PROTOCOL.md`
- `BLE_BACKLOG_SYNC_PROTOCOL.md`
- `GUIDED_RESCUE_PHASE1.md`

L’índex handoff els marca com el paquet final obligatori per al desenvolupador app/BLE. :contentReference[oaicite:5]{index=5}

---

## 5. Scope tancat respecte firmware vs app/backend

Queda tancat que:

- `EixamRoute` no s’implementa a firmware
- Rescue avançat (fase 2) no s’implementa a firmware
- seguiment de ruta, desviacions i workflow avançat de rescat viuen a app/backend

En el context del monorepo SDK-first, això s’ha de traduir en:
- lògica i contractes de producte al SDK
- app host com a superfície de representació i operació

No s’ha de moure aquesta lògica a widgets de l’app. :contentReference[oaicite:6]{index=6}

---

## 6. Guided Rescue — decisió actual

Guided Rescue Fase 1 s’ha d’exposar al host a través del SDK, no com a bytes o operacions protocol·làries directes a la UI.

La fase 1 es basa en:

- `REQUEST_POS`
- `ACK_SOS`
- `BUZZER_ON`
- `BUZZER_OFF`
- `STATUS_REQ`

i una resposta `STATUS_RESP` al port 261.

La lògica de càlcul de distància/rumb, proximitat i accions guiades és de capa superior (SDK-facing / app/backend), no de firmware. 

---

## 7. Backlog sync — decisió actual

El backlog sync BLE és una capacitat real del sistema i no s’ha de modelar com a hack puntual d’app.

Quan s’implementi o s’ampliï, ha de viure com a comportament i contracte del SDK:
- control de sessió
- pujada diferida
- persistència
- ACK coherent
- idempotència

L’app només ha de reflectir-ne estat i accions. :contentReference[oaicite:8]{index=8}

---

## 8. Components UI reutilitzables

Quan existeixin components reutilitzables del package UI, s’han de preferir davant de widgets duplicats a l’app host.

Exemple:
- botons SOS
- components d’estat
- patrons visuals de seguretat

Això reforça el model SDK-first i redueix divergència entre integracions. :contentReference[oaicite:9]{index=9}

---

## 9. Testing — criteri de prioritat

La cobertura automatitzada s’ha de concentrar primer al SDK, no a la demo app.

Ordre de prioritat:
1. lògica pura
2. use cases
3. state machines
4. contractes públics del SDK
5. persistència
6. adapters/repositories crítics
7. widget tests reutilitzables
8. smoke tests de l’host app

Això està alineat amb l’estat actual del projecte i amb la necessitat de hardening del SDK. :contentReference[oaicite:10]{index=10}

---

## 10. Demo app / Control App

La demo app actual és una validation host útil, però no s’ha de tractar com a app final de producte.

A curt termini, s’accepta que serveixi per:
- validació operativa
- validació tècnica
- proves internes

A mig termini, s’ha de mantenir neta, prima i desacoblada de la lògica crítica. 

---

## 11. Decisions actives de roadmap

A nivell de seqüència de treball, les prioritats actives són:

1. consolidar documentació
2. hardening del SDK
3. testing strategy i cobertura útil
4. refinament del mòdul device / BLE readiness
5. Guided Rescue Fase 1 sobre contractes nets
6. backlog sync
7. tuning de consum / validació de camp quan pertoqui

El roadmap de firmware indica que la base fins Rescue fase 1 està feta i que encara queden validacions i tuning de consum. 

---

## 12. Anti-patterns a evitar

No fer:

- lògica crítica a widgets
- parsing i dedup importants a pantalles
- rescues implementats “ad hoc” a l’app
- APIs públiques del SDK massa crues si obliguen la host app a interpretar massa
- duplicació de components reutilitzables del package UI
- sobreenginyeria sense retorn clar

---

## 13. Regla de decisió

Davant qualsevol canvi, preguntar sempre:

**Això fa el SDK més reusable o més fiable?**

Si la resposta és no, probablement no és prioritari ara.