# Validation Checklist: Protection Mode

## Backward Compatibility

1. Start the app and do not arm Protection Mode.
2. Validate current BLE, SOS, telemetry, and device flows still behave as before.

## Android Full-Ownership Path

1. Pair and connect a trusted device.
2. Run Protection readiness.
3. Enter Protection Mode.
4. Confirm:
   - `modeState` is not `off`
   - `bleOwner=androidService`
   - foreground service is running
   - Flutter no longer behaves as the active BLE owner while armed
   - runtime/platform events are visible
5. Rehydrate Protection state and confirm the snapshot remains coherent.
6. Flush queues and confirm queue counters respond safely.
7. Exit Protection Mode and confirm ownership/runtime return to the default off path.

## Android Background / Restart

1. Arm Protection Mode.
2. Background the app.
3. Re-open and run rehydrate.
4. Confirm:
   - foreground service state is still reflected
   - BLE owner is still reported coherently
   - reconnect counters and last platform/BLE service events remain available

## iOS Base / Readiness Path

1. Launch on iOS.
2. Run Protection readiness.
3. Confirm status remains honest:
   - platform is `ios`
   - coverage is `partial` or otherwise degraded
   - background capability state is visible
   - restoration configured and last restoration event fields are visible
   - degradation reason explains the current limitation
4. Enter and rehydrate Protection Mode and confirm there are no crashes or false `full` claims.

## Expected Outcomes

- Protection Mode never auto-arms.
- Non-Protection flows remain unchanged.
- Android reports service ownership/readiness details when armed.
- iOS reports safe base participation with honest limitations.
