# NEXT_STEPS.md

## Current status

The project is currently in a good intermediate state:

- the monorepo is runnable
- the SDK bootstrap is stable
- the reference app works
- main modules are already wired
- mock realtime is exposed publicly
- BLE is abstracted but not yet production-ready
- WebSocket production integration is intentionally postponed

---

## Current goal

Continue maturing the **EIXAM Connect SDK** while keeping the reference app usable for validation.

The focus should remain on:
- SDK quality
- explicit contracts
- stable architecture
- documentation
- developer onboarding

---

## What is already done

### Core and SDK foundation
- SDK-first structure validated
- monorepo structure working
- core/public interfaces in place
- Flutter SDK runtime implementation in place

### Functional modules
- SOS
- tracking
- permissions
- notifications
- emergency contacts
- Death Man Protocol
- device module

### Technical infrastructure
- local persistence
- defensive bootstrap
- BLE provider skeleton
- mock BLE client
- realtime skeleton
- mock realtime client
- realtime public API exposure
- cached realtime state and last event

### Validation surface
- reference Control app working
- demo sections for module validation

---

## Immediate recommended next steps

### 1. Consolidate documentation
Create and maintain the following docs in the repo:
- `README.md`
- `RUN_PROJECT.md`
- `SDK_ARCHITECTURE.md`
- `AGENTS.md`
- `NEXT_STEPS.md`
- `AGENTS_SUMMARY_CONTEXT.md`

### 2. Clean and organize documentation ownership
Decide which document is:
- master overview
- run guide
- architecture reference
- integration guide
- agent context

### 3. Improve SDK internal quality
Potential improvements:
- review naming consistency
- reduce duplication
- make module boundaries clearer
- improve public API clarity
- improve lifecycle/dispose consistency

### 4. Add tests where highest value exists
Suggested initial focus:
- SOS state restoration
- Death Man flows
- realtime cached state
- device state transitions
- permissions behavior where mockable

### 5. Keep the demo app stable
The reference app should remain a fast manual validation surface, not an experimental playground.

---

## Work that should wait

The following should **wait for backend definition**:

### WebSocket production integration
Do not finalize:
- message schema
- auth handshake
- reconnect behavior
- server event types
- subscription protocol

### Final realtime production contract
Do not hardcode assumptions that backend has not confirmed.

### Production BLE integration
Do not overbuild the final BLE client before device/backend expectations are clear enough.

---

## Recommended backlog buckets

## A. Documentation and onboarding
- [ ] Finalize `README.md`
- [ ] Add/confirm `RUN_PROJECT.md`
- [ ] Finalize `SDK_ARCHITECTURE.md`
- [ ] Add `AGENTS.md`
- [ ] Add `NEXT_STEPS.md`
- [ ] Review old/duplicate docs and consolidate

## B. SDK hardening
- [ ] Review public API consistency
- [ ] Review dispose/lifecycle consistency
- [ ] Review repository restoration safety
- [ ] Review realtime cache behavior
- [ ] Review persistence rules for transient states

## C. Demo/reference app quality
- [ ] Keep bootstrap clear and stable
- [ ] Keep module validation sections working
- [ ] Optionally split `main.dart` into smaller files later
- [ ] Avoid unnecessary demo-only complexity

## D. Testing
- [ ] Add unit tests for SOS state logic
- [ ] Add unit tests for Death Man Protocol
- [ ] Add tests for cached realtime state
- [ ] Add tests for persistence restore scenarios

## E. Backend-aligned future work
- [ ] Finalize realtime contract with backend
- [ ] Implement `WebSocketRealtimeClient`
- [ ] Map backend messages to `RealtimeEvent`
- [ ] Add reconnect strategy if required
- [ ] Validate auth/session integration

## F. BLE future work
- [ ] Implement real BLE client
- [ ] Validate provisioning flow
- [ ] Validate pair/activate lifecycle
- [ ] Align with actual device constraints

---

## Suggested next technical milestone

### Milestone
**SDK documentation + hardening checkpoint**

### Goal
Before continuing with production realtime or production BLE:
- make the SDK easier to understand
- reduce onboarding cost
- keep the architecture stable
- add a minimum quality layer

This milestone is more valuable right now than implementing speculative backend-dependent features.

---

## Suggested future milestone after backend input

### Milestone
**Production realtime transport integration**

### Goal
Implement:
- `WebSocketRealtimeClient`
- agreed server protocol mapping
- event decoding
- connection lifecycle behavior
- integration inside the SDK runtime

Only start this once backend provides the required definitions.

---

## Suggested commit strategy

Use small commits per coherent block.

Examples:
- `docs: add shared agent context and project next steps`
- `refactor: improve SDK lifecycle and state handling`
- `test: add coverage for SOS restore and realtime cache`
- `feat: add websocket realtime client skeleton`

---

## Team alignment notes

When resuming work:
- start from the top-level repo only
- do not use nested duplicate repo copies
- keep SDK-first mindset
- document important decisions
- avoid speculative backend implementations

---

## Current recommended focus

If development continues without backend realtime definition, the best next area is:

1. documentation consolidation
2. SDK hardening
3. test coverage
4. cleanup/refactor of demo structure only if useful

This keeps momentum high without building the wrong production contract too early.
