# Core Concepts

## SDK-first

EIXAM is built SDK-first. The SDK owns the core safety/runtime logic and the host app consumes that logic through stable contracts.

## Bootstrap vs session lifecycle

### Bootstrap

`bootstrap(...)` creates the SDK instance and resolves environment configuration.

### Session lifecycle

`setSession(...)`, `clearSession()`, and `getCurrentSession()` manage the signed identity lifecycle after bootstrap.

## Signed identity vs canonical identity

### Signed identity

The partner backend provides:

- `appId`
- `externalUserId`
- `userHash`

### Canonical identity

The SDK can enrich the identity through `/v1/sdk/me` so internal runtime flows use the canonical backend identity for transport and topic resolution.

## Standard vs custom environments

Use standard environments whenever possible:

- `production`
- `sandbox`
- `staging`

Use `custom` only when you explicitly control alternative endpoints.

## Runtime-sensitive actions

Some capabilities are deliberately UX-sensitive and must remain explicit host-app decisions:

- requesting permissions
- entering Protection Mode
- device pairing / connection
- starting tracking
- showing partner-branded UI flows

## Validation app vs partner app

The validation app is an internal thin host used to test and observe SDK behavior. It is not the reference product UX for partners.
