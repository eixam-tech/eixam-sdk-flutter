# Codex Rules

- Always inspect [`AI_INDEX.md`](AI_INDEX.md) first.
- Keep changes small, local, and task-focused.
- Do not duplicate SDK logic in the app.
- Do not move BLE parsing, relay routing, or SOS orchestration into widgets.
- Do not break existing SOS, BLE, DMP, protection, or relay flows.
- Prefer SDK public facades before reaching into internal layers.
- Preserve the SDK-first architecture from `AGENTS.md`.
- If behavior is unclear, preserve current behavior and mark the uncertainty as `Needs verification`.
- Always mention exact files changed in the final response.
- Always explain:
  - root cause
  - solution
  - validation performed
  - tests run or not run
- When updating docs, keep them factual and tied to current repository code.
- When changing runtime behavior, read the relevant tests first and update/add tests with the change.
