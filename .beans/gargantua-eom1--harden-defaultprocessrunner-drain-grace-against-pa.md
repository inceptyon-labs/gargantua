---
# gargantua-eom1
title: Harden DefaultProcessRunner drain-grace against parallel subprocess scheduling starvation
status: in-progress
type: bug
priority: low
created_at: 2026-04-18T20:10:16Z
updated_at: 2026-04-20T01:02:31Z
parent: gargantua-qe4a
---

While adding real-process integration tests in gargantua-jgwm, discovered a pre-existing race in `DefaultProcessRunner.run(...)`: under heavy parallel subprocess load, the bounded drain wait can time out even when stdout is already buffered in the pipe, because the background drain task hasn't been scheduled yet by the global utility queue.

## Reproduction

Before the `.serialized` trait was added to `DefaultProcessRunnerIntegrationTests`, running the full test suite (461 tests, 10+ of which spawn real subprocesses via `DefaultProcessRunner`) reliably failed this pre-existing test:

```
DefaultProcessRunnerTests.swift:121 - "Process completes normally within timeout"
→ #expect(output.stdout.contains("hello"))
  output.stdout is empty
  Command: /bin/sh -c "echo 'hello'; exit 42"
  Timeout: 5.0s
```

Happens on 3/3 consecutive full-suite runs. Serializing the new integration suite works around it by keeping peak concurrent subprocess count at 6+1 instead of 6+4.

## Root Cause

`Sources/GargantuaCore/Services/ProcessRunner.swift:166-182`:

```swift
let drainGracePeriod: DispatchTime = {
    let graceSecs = timeout.map { min(max($0 * 0.1, 0.1), 1.0) } ?? 1.0
    return DispatchTime.now() + graceSecs
}()

let drainResult = drainGroup.wait(timeout: drainGracePeriod)
if drainResult == .timedOut {
    try? outHandle.close()
    try? errHandle.close()
    _ = drainGroup.wait(timeout: DispatchTime.now() + 0.1)
}
```

For `timeout: 5.0`, `graceSecs` = 0.5s. Under parallel load, the `.utility` QoS drain tasks may not get CPU within 0.5s, so the force-close path runs, closes the fds, and the belated `readToEnd()` returns empty instead of the 6-byte "hello\n" already sitting in the pipe.

## Acceptance Criteria

- [ ] Remove the `.serialized` trait from `DefaultProcessRunnerIntegrationTests` and confirm the full suite passes deterministically across 5 consecutive runs
- [ ] Pick one (or combine) of these fixes:
  - Bump drain queue QoS from `.utility` to `.userInitiated` so drain tasks aren't starved by other utility work
  - Raise the drain-grace floor (e.g. minimum 1.0s) since stdout is bounded and the child has already exited
  - Skip the force-close path entirely when `coordinator.markNaturalCompletion()` returned `.naturallyCompleted` — the process is gone, the pipe writer is closed, `readToEnd()` will return promptly once scheduled
- [ ] Keep existing `timeoutCleansDescendantAfterLeaderExits` and `descendantInheritedFdHandling` tests green (force-close must still fire when a descendant holds the fd)

## Context

- Sibling bean: gargantua-566u (`posix_spawn(POSIX_SPAWN_SETPGROUP)` for setpgid race)
- Parent epic: gargantua-qe4a (Phase 2 Intelligence)
- Surfaced by: gargantua-jgwm (this commit: c6e1d48)
