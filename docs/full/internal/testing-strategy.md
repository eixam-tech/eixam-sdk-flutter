# EIXAM SDK — Testing Strategy

## Purpose

This document defines how automated testing should be approached in the EIXAM monorepo.

The goal is not to maximize coverage for vanity metrics.
The goal is to maximize confidence, regression safety, and SDK reusability.

Because EIXAM is SDK-first, testing priority must be centered on the SDK packages rather than on the reference host app.

---

## 1. Testing principles

### 1.1 SDK-first testing

The SDK is the product core.
Therefore, the most important automated tests are the ones that protect:

- domain behavior
- public SDK contracts
- state transitions
- persistence behavior
- integration boundaries inside the SDK

### 1.2 Prefer behavior over implementation details

Tests should validate:

- what the SDK guarantees
- what consumers can rely on
- how state evolves
- how public APIs behave

Tests should avoid overfitting to private implementation details.

### 1.3 Prefer fakes over excessive mocking

When possible, prefer:

- in-memory repositories
- fake providers
- fake clocks
- fake ID generators
- local stream helpers

This keeps tests more stable and easier to maintain.

### 1.4 App host is not the main coverage target

`apps/eixam_control_app` is useful for smoke testing and manual validation,
but it is not the main target for broad automated coverage.

The main automated effort should go to:

- `packages/eixam_connect_core`
- `packages/eixam_connect_flutter`
- selected reusable pieces in `packages/eixam_connect_ui`

---

## 2. Testing pyramid for EIXAM

### 2.1 Base layer — Unit tests

Highest priority.

Focus on:

- entities
- value validation
- enums / mappings
- parsers / codecs
- use cases
- reducers / state machines
- pure transformation logic

### 2.2 Middle layer — Contract / integration tests

Second priority.

Focus on:

- public SDK APIs
- repositories
- persistence behavior
- controllers/services
- adapters
- observable streams
- cross-module state behavior

### 2.3 Upper layer — Widget tests

Selective priority.

Focus on:

- reusable SDK UI components
- critical component states
- loading / enabled / disabled / error rendering

### 2.4 Top layer — Host app smoke tests and manual testing

Lowest automated priority.

Focus on:

- app boots correctly
- main SDK wiring still works
- no obvious integration regressions

Real device / BLE / field validation remains essential, but is not a substitute for SDK automated testing.

---

## 3. Package-by-package strategy

## 3.1 `packages/eixam_connect_core`

This package should carry the strongest test density.

Priority areas:

- SOS state machine and use cases
- Tracking state transitions
- stale detection logic
- Death Man logic
- emergency contacts domain rules
- device lifecycle/status modeling
- public SDK interface contracts where defined
- domain errors and defensive behavior

Expected test types:

- unit tests
- state transition tests
- contract behavior tests

## 3.2 `packages/eixam_connect_flutter`

This package should focus on runtime behavior and integration boundaries.

Priority areas:

- repositories
- persistence serializers / restore flows
- permission adapters
- notification integration boundaries
- device runtime providers
- SDK implementation behavior
- latest-state caches / stream exposure

Expected test types:

- contract tests
- in-memory integration tests
- persistence tests
- defensive bootstrap tests

## 3.3 `packages/eixam_connect_ui`

This package should be tested selectively.

Priority areas:

- reusable SOS UI
- shared action components
- localization surface where relevant
- critical visual states

Expected test types:

- widget tests

## 3.4 `apps/eixam_control_app`

This app should not become the center of test effort.

Recommended coverage:

- minimal smoke tests
- maybe one or two navigation/bootstrap sanity tests
- mostly manual validation for integration scenarios

---

## 4. Priority order for current project phase

Given the current state of the project, the recommended testing order is:

1. SOS domain/state transitions
2. Death Man domain/state transitions
3. Tracking state transitions and stale logic
4. Device status/lifecycle contracts
5. Emergency contacts behavior and persistence
6. Public SDK façade contracts
7. Persistence restore/save behavior
8. Permission orchestration behavior
9. Realtime façade behavior
10. Reusable UI widget tests
11. Host app smoke tests

This order reflects the current architecture and the current maturity of the project.

---

## 5. Public contract testing

Because the SDK is the reusable product, public contract tests are critical.

These tests should verify what host apps can safely rely on, such as:

- triggering SOS
- cancelling SOS
- monitoring SOS state
- starting/stopping tracking
- observing tracking state and positions
- scheduling / confirming / cancelling Death Man flows
- listing / adding / updating / removing emergency contacts
- retrieving and observing device status
- observing realtime state where exposed

Public contract tests are more valuable than testing many internal classes in isolation.

---

## 6. Persistence testing

Persistence is already relevant in the project and should be treated as a first-class concern.

At minimum, persistence tests should cover:

- SOS persisted state restore
- tracking restore behavior
- Death Man restore behavior
- emergency contacts restore behavior
- device status restore behavior where applicable
- defensive handling of invalid or transitional persisted data

Prototype persistence is acceptable at this stage, but regressions in restore/bootstrap behavior are high-risk.

---

## 7. BLE / device-related testing stance

BLE and device integration are architecturally important from day one.

Testing should reflect that in two layers:

### 7.1 Contract level
Test:

- device runtime boundaries
- observable status behavior
- activation / pairing / refresh expectations
- defensive behavior when runtime data is incomplete

### 7.2 Real environment validation
Manual or dedicated integration validation should still happen for:

- real BLE plugin behavior
- real device interactions
- notify/write timing
- field behavior

Automated SDK tests should protect contracts even before full real BLE runtime is finalized.

---

## 8. APP/BLE integration minimums to protect

The app/BLE handoff establishes a minimum expected implementation surface for the app side:

- TEL 10B parsing
- SOS 5B/10B parsing
- `0xD0` TEL fragment reassembly
- TEL/SOS deduplication
- offline tolerance and retry queue
- backlog sync support when applicable
- Rescue Phase 1 support
- robust backend pipeline behavior

Where these behaviors live inside the SDK or SDK-facing integration layer, they should become test targets.

---

## 9. Test infrastructure guidelines

Recommended shared testing utilities:

- builders / factories for domain entities
- fake repositories
- fake runtime providers
- in-memory persistence
- fake clock / time source
- fake ID generator
- stream expectation helpers
- helper methods for repeated state setup

Shared helpers should reduce duplication without becoming their own mini-framework.

---

## 10. When tests reveal architecture problems

A difficult-to-test area is often a design signal.

If a module is hard to test, document whether the problem is:

- too much coupling
- missing interface boundaries
- raw state too hard for consumers
- hidden side effects
- mixed responsibilities
- app-owned logic that should belong in the SDK

Do not hide poor architecture under brittle tests.

---

## 11. Definition of “good enough” for a module

A module is not “good enough” just because the demo app seems to work.

At minimum, a mature-enough SDK module should have:

- clear public behavior
- stable state transitions
- defensive error handling
- meaningful tests for the main paths
- persistence coverage where applicable
- no critical dependency on host app UI logic

---

## 12. Current practical next steps

For the current phase of the project, the recommended sequence is:

1. strengthen shared test infrastructure
2. harden core state transitions
3. harden public SDK contracts
4. harden persistence restore/save behavior
5. identify SDK testability gaps
6. only then expand toward Guided Rescue Phase 1 and backlog sync coverage

---

## 13. Final rule

We do not add tests just to say we have tests.

We add tests that make the SDK:

- safer to change
- easier to integrate
- harder to break
- more trustworthy as a product
