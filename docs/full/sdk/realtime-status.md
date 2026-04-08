# Realtime Status

Realtime support exists as a public surface, but backend protocol maturity still matters.

## Current public surfaces

- `getRealtimeConnectionState()`
- `getLastRealtimeEvent()`
- `watchRealtimeConnectionState()`
- `watchRealtimeEvents()`

## Integration rule

Do not hardcode a final production transport contract blindly. Follow the current backend-agreed transport and topic semantics.

## Host-app expectation

Render realtime as diagnostics/operational state, not as the only source of truth for every lifecycle transition unless the backend contract explicitly says so.
