---
# gargantua-jgwm
title: Real-Process integration tests for DefaultProcessRunner timeout path
status: completed
type: task
priority: low
created_at: 2026-04-17T21:12:44Z
updated_at: 2026-04-18T20:07:00Z
parent: gargantua-qe4a
---

Current ProcessRunner tests only use StubRunner implementations that return canned ProcessOutput. The timeout watchdog, AtomicFlag coordination, and pipe draining in DefaultProcessRunner itself are entirely uncovered by tests. The fclones SC review Pass 2 flagged this as a warning.

Add a small integration-test suite that forks real /bin/sh commands:
- [x] /bin/sleep 5 with timeout: 0.2 → expect ProcessRunnerError.timedOut
- [x] /bin/echo "hello" with no timeout → expect stdout == "hello\n"
- [x] /bin/sh -c "exit 7" → expect exitCode == 7
- [x] Large-payload /bin/sh -c "yes | head -c 100000" → expect no deadlock and full capture

Keep wall-clock short (<1s each) so they don't slow CI. These tests belong under Tests/GargantuaCoreTests/Services/DefaultProcessRunnerIntegrationTests.swift or similar.


## Summary of Changes

Added `Tests/GargantuaCoreTests/Services/DefaultProcessRunnerIntegrationTests.swift` with the four contract test cases:

- `/bin/sleep` with 0.2s timeout → `ProcessRunnerError.timedOut(0.2)`
- `/bin/echo hello` (no timeout) → stdout == "hello\n", exit 0
- `/bin/sh -c "exit 7"` → exitCode == 7
- `/bin/sh -c "yes | head -c 100000"` → full 100000-byte capture, no deadlock

**Implementation note:** The suite is marked `.serialized`. Running all four subprocess tests in parallel alongside the existing `DefaultProcessRunnerTests` suite (6 tests) reliably reproduced an empty-stdout failure in the pre-existing `completesWithinTimeout` test. Under heavy concurrent subprocess load, the drain-grace timeout (0.5s for a 5s-timeout config) can elapse before the background drain queue is scheduled to read the pipe, triggering the force-close path and losing already-buffered stdout. Serializing the new suite keeps peak concurrent subprocess count at 6+1 instead of 6+4 and makes the full suite pass deterministically across 3 consecutive runs.

Wall-clock budget per test: all four complete in under 0.25s, well inside the <1s constraint.

Follow-up consideration (not in scope for this bean): the drain-grace race in `DefaultProcessRunner` is a real pre-existing flake under load. Worth a separate bean to either raise the grace floor, bump the drain queue QoS, or skip force-close when natural completion already won the timeout race.
