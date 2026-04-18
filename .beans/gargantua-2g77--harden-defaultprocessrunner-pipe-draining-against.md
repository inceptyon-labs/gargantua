---
# gargantua-2g77
title: Harden DefaultProcessRunner pipe draining against handler/readToEOF race
status: completed
type: task
priority: low
created_at: 2026-04-17T21:12:38Z
updated_at: 2026-04-18T13:16:54Z
parent: gargantua-qe4a
---

Current DefaultProcessRunner.run() installs a readability handler that appends each chunk to a shared buffer, then after waitUntilExit nils the handler and calls readDataToEndOfFile() to drain the tail. Apple's docs are ambiguous about whether setting the handler to nil blocks for in-flight invocations, so a handler chunk racing with readDataToEndOfFile() can in principle produce interleaved or duplicated bytes.

Pre-existing from the CzkawkaAdapter lineage and has not caused observed problems, but flagged in the fclones SC review (Pass 2). Cleanup: switch to a single-path drain — either handler-only with an EOF sentinel (empty-chunk detection) or a dedicated blocking-read DispatchQueue per pipe that join()s after waitUntilExit. Add a test that forks /bin/echo of a large payload and asserts byte-for-byte stdout capture to exercise the path.

Scope:
- [x] Decide on drain strategy (handler-EOF vs background blocking-read) — chose background blocking-read per pipe
- [x] Refactor DefaultProcessRunner accordingly
- [x] Add real-Process test for large-stdout capture
- [x] Verify Czkawka and fclones adapters still pass unchanged

## Summary of Changes

**Strategy chosen:** dedicated blocking-read DispatchQueue per pipe (over handler-EOF).

**Reasoning:** A single `readDataToEndOfFile()` per pipe returns exactly once with all bytes up to EOF — no possible interleave between a late readabilityHandler chunk and a post-exit drain. Simpler to reason about than the empty-chunk sentinel approach.

### Files changed

- `Sources/GargantuaCore/Services/ProcessRunner.swift` — replaced `readabilityHandler` + post-exit `readDataToEndOfFile()` pair with two background blocking reads joined by a DispatchGroup. Reads are scheduled after `process.run()` so no orphan queue tasks if launch throws. Pipe ends close on child exit, so `drainGroup.wait()` returns shortly after `waitUntilExit`.
- `Tests/GargantuaCoreTests/Services/DefaultProcessRunnerTests.swift` — new test forking `/bin/sh -c 'yes | head -c 100000'` to exercise a payload larger than the 64K pipe buffer. Asserts byte-for-byte capture.

### Review outcome

SC (Sonnet → Codex). Sonnet: no errors. Codex flagged two pre-existing weaknesses not introduced by this refactor:
1. `readDataToEndOfFile()` can hang if a descendant inherits the pipe fd.
2. Timeout uses only SIGTERM (no SIGKILL escalation).

Filed as follow-up: **gargantua-gcf8** (process-group + SIGKILL escalation + bounded drain wait).

Review-pass feedback applied to this change: tightened the drain comment to state EOF requires *every* writer to close, and corrected a misleading comment in the test.

### Verification

- 452/452 tests pass (was 451 baseline + 1 new)
- `swift build` clean
- `swiftlint` clean
- Czkawka and fclones adapters unchanged (StubRunner, not affected)
