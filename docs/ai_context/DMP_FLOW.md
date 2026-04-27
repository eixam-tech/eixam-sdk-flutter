# DMP Flow

## What DMP Does

- DMP here is the Death Man Protocol.
- It monitors an expected return time and can escalate into SOS if the user does not confirm safety during the check-in window.
- Public SDK surface lives on `EixamConnectSdk`.

## Main States

- `scheduled`
- `monitoring`
- `overdue`
- `awaitingConfirmation`
- `confirmedSafe`
- `escalated`
- `cancelled`
- `expired`

State transitions are enforced by `packages/eixam_connect_core/lib/src/state/death_man_state_machine.dart`.

## Runtime Behavior

1. `scheduleDeathMan(...)` creates a plan.
2. SDK immediately updates it to `monitoring`.
3. A 1-second timer in `EixamConnectSdkImpl` evaluates deadlines.
4. After `expectedReturnAt`, plan moves to `overdue`.
5. After `expectedReturnAt + gracePeriod`, plan moves to `awaitingConfirmation`.
6. After `expectedReturnAt + gracePeriod + checkInWindow`, plan moves to `escalated`.
7. If `autoTriggerSos` is true, SDK triggers SOS with `triggerSource: death_man_protocol`.
8. Plan is then set to `expired`.

## Notification Behavior

- SDK sends local notifications on overdue and awaiting-confirmation transitions.
- Confirm action label is `I'm OK`.
- Notification handling goes through the same SDK notification action entry point.
- If the user taps `I'm OK`, SDK confirms the plan; if the same plan still remains active, SDK then cancels it.

## Timer / Reconciliation Rules

- Monitoring is resumed on SDK initialization if there is an active monitorable plan.
- Notification flags are reconstructed from current plan state when resuming:
  - awaiting confirmation implies check-in notification already considered sent
  - overdue or awaiting confirmation implies overdue notification already considered sent
- The DMP timer is SDK-owned, not app-owned.

## What Happens When Idle

- If there is no active plan, `DeathManController.activePlan` is `null`.
- Terminal states are treated as inactive:
  - `cancelled`
  - `confirmedSafe`
  - `expired`

## Main Files

- `packages/eixam_connect_flutter/lib/src/sdk/eixam_connect_sdk_impl.dart`
- `packages/eixam_connect_flutter/lib/src/sdk/death_man_controller.dart`
- `packages/eixam_connect_flutter/lib/src/data/repositories/in_memory_death_man_repository.dart`
- `packages/eixam_connect_core/lib/src/state/death_man_state_machine.dart`
- `packages/eixam_connect_core/lib/src/entities/death_man_plan.dart`

## Related Tests

- `packages/eixam_connect_core/test/state/death_man_state_machine_test.dart`
- `packages/eixam_connect_flutter/test/data/repositories/in_memory_death_man_repository_test.dart`
- `packages/eixam_connect_flutter/test/sdk/eixam_connect_sdk_impl_test.dart`

## Needs Verification

- DMP persistence is implemented with the in-memory repository plus local store persistence, but there is no backend-backed DMP repository in this repo. Any future server-driven DMP behavior would need separate confirmation before documenting it as current behavior.
