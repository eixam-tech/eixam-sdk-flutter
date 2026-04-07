# SDK Test Caveats

## Protection Platform Adapter Tests

The direct `MethodChannel`-driven protection adapter tests were not terminating reliably in the current headless Windows Flutter test runner, even after adding explicit per-test timeouts and teardown.

To keep CI deterministic, the focused adapter suites now validate the concrete channel-mapping contract through a shared pure mapper layer instead of live `MethodChannel` execution.

This keeps the important functional coverage:

- native snapshot mapping
- start / flush / command result mapping
- platform event mapping

If direct channel smoke coverage is needed later, it should run in a dedicated platform-aware environment rather than the current headless unit-test path.
