# Guided Rescue Phase 1 SDK Contract

This document captures the minimal public SDK contract proposed for Guided Rescue Phase 1.

## Public SDK API

The SDK now exposes a session-oriented rescue surface:

- `getGuidedRescueState()`
- `watchGuidedRescueState()`
- `setGuidedRescueSession(targetNodeId, rescueNodeId)`
- `clearGuidedRescueSession()`
- `requestGuidedRescuePosition()`
- `acknowledgeGuidedRescueSos()`
- `enableGuidedRescueBuzzer()`
- `disableGuidedRescueBuzzer()`
- `requestGuidedRescueStatus()`

## Public state models

- `GuidedRescueState`
  - current rescue session context
  - latest target position snapshot
  - latest structured rescue status
  - action availability
  - runtime support / unsupported reason
  - last error

- `GuidedRescueStatusSnapshot`
  - target node id
  - rescue node id
  - target SOS/rescue state
  - battery level
  - GPS quality
  - retry count
  - relay pending ACK flag
  - internet availability flag

## Runtime integration point

`GuidedRescueRuntime` is the internal extension seam that should later own:

- command dispatch to the rescue channel/port
- `STATUS_RESP` decoding
- rescue action availability
- rescue session lifecycle
- integration with TEL/SOS/device streams

## Current incremental behavior

- The public contract exists now.
- The current SDK implementation exposes an unsupported rescue state until runtime orchestration is wired in.
- The host app can render rescue state and session context without owning rescue logic.

## Open questions

- How should rescue session selection be seeded: backend assignment, manual selection, or both?
- Should target position come only from rescue pushes, or also from normal TEL-derived tracking when available?
- Which actions should be allowed in each target state?
- Should rescue state be reset on device disconnect, or preserved as pending operational context?
