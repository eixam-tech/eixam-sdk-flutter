# EIXAM Connect SDK

EIXAM Connect SDK is the partner-facing integration layer of EIXAM's connected safety platform.

This monorepo is **SDK-first**:

- the SDK is the product foundation
- host apps stay thin and consume SDK contracts
- `apps/eixam_control_app` is a validation host, not the final partner UX
- critical safety logic belongs in the SDK/runtime layers, not in app widgets

## What changed in this documentation set

This documentation set is aligned to the **single-call bootstrap flow**:

- `EixamConnectSdk.bootstrap(...)` is the recommended public entrypoint
- `production`, `sandbox`, and `staging` are resolved internally
- `custom` requires `EixamCustomEndpoints`
- `initialSession` is optional, but when provided it must match the bootstrap `appId`
- `bootstrap(...)` does **not** request permissions, pair devices, or trigger UX-sensitive actions

## Documentation entrypoints

### Partner docs

Open the generated partner portal at:

- `site/partner/index.html`

Source Markdown lives under:

- `docs/partner/`

### Full / internal docs

Open the full technical portal at:

- `site/full/index.html`

Source Markdown lives under:

- `docs/full/`

## Repository structure

- `apps/eixam_control_app` — reference/validation host app
- `packages/eixam_connect_core` — public contracts, entities, enums, state models
- `packages/eixam_connect_flutter` — runtime implementation, persistence, BLE, protection, MQTT, permissions
- `packages/eixam_connect_ui` — reusable UI helpers
- `docs/` — Markdown source of truth for partner and full portals
- `site/` — generated HTML output

## Best place to start

- Partner integration: `docs/partner/quickstart.md`
- Public SDK surface: `docs/partner/public-api.md`
- Exhaustive method examples: `docs/partner/public-api-examples.md`
- Internal architecture: `docs/full/sdk/architecture.md`

## Release artifacts

A partner-ready SDK release should include:

- a versioned SDK tag
- `docs/partner/`
- `docs/full/`
- `site/partner/`
- `site/full/`
- onboarding and integration notes as applicable

Use these artifacts together so partners receive the SDK version, the
partner-facing guidance, and the deeper technical reference in one release
package.

For the wider release readiness checklist, see `docs/sdk/SDK_RELEASE_CHECKLIST.md`.

## Developer onboarding

- project runbook: `HOW_TO_RUN_PROJECT.md`
- internal engineering contract: `AGENTS.md`
- package docs: `packages/eixam_connect_flutter/README.md`
