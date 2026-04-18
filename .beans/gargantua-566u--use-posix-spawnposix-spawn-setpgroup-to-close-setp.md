---
# gargantua-566u
title: Use posix_spawn(POSIX_SPAWN_SETPGROUP) to close setpgid race in DefaultProcessRunner
status: completed
type: task
priority: low
created_at: 2026-04-18T19:52:30Z
updated_at: 2026-04-18T20:38:09Z
parent: gargantua-qe4a
---

Follow-up from gargantua-gcf8. Current implementation calls `setpgid` on the child from the parent after `process.run()`, which is inherently racy: a child that forks descendants before the parent's `setpgid` runs will leave those descendants in the parent's group rather than the child's. `Foundation.Process` doesn't expose pre-exec hooks, so closing the race requires replacing (or wrapping) `Foundation.Process` with a direct `posix_spawn` call using `POSIX_SPAWN_SETPGROUP`.

Scope:
- [x] Wrap `posix_spawn` in a minimal Swift helper that matches `DefaultProcessRunner`'s needs (exec + args + pipes)
- [x] Migrate `DefaultProcessRunner.run` to the helper, preserving existing timeout/drain/escalation behavior
- [x] Remove the post-spawn `setpgid` and its `hasPgid` fallback
- [x] Keep (or update) existing integration tests; they should continue to pass
- [x] Consider whether the same pattern belongs in a shared `ProcessSpawner` primitive

Related: gargantua-gcf8 (initial hardening), gargantua-2g77 (drain refactor).


## Summary of Changes

Replaced `Foundation.Process` + post-spawn `setpgid` with direct `posix_spawn(POSIX_SPAWN_SETPGROUP)` so the child is its own pgroup leader atomically before exec.

**New file:** `Sources/GargantuaCore/Services/ProcessSpawner.swift` — minimal `posix_spawn` wrapper. File actions dup2 pipe write ends to stdout/stderr and conditionally addclose the four pipe fds (skipping when a fd aliases the stdio slot we just dup2'd into, to avoid closing our own redirected stdio). Every `posix_spawn_file_actions_*` / `posix_spawnattr_*` return value is checked. `strdup` NULL failures surface as `ENOMEM` instead of silently truncating argv/envp.

**Modified:** `Sources/GargantuaCore/Services/ProcessRunner.swift` — `DefaultProcessRunner.run` no longer creates a `Foundation.Process`. It spawns via the helper, manages the child by pid (`waitpid` with `EINTR` retry for wait-until-exit, `killpg` for TERM/KILL), and extracts exit codes by bit-math on the waitpid status word. Removed the `hasPgid` fallback branch entirely. `TimeoutCoordinator` gained `markReaped()` + `shouldEscalateKill()` so the 0.5s-delayed `SIGKILL` escalation can't land on a recycled pgid after `waitpid` freed it; `tryArmTimeout` also refuses to arm once reaped, reducing the close-race false-positive where a child that exited at the deadline could be reported as timed out. New `ProcessRunnerError.waitFailed(errno:)` surfaces non-EINTR `waitpid` failures instead of silently returning exit 0.

**Tests:** All 10 existing `DefaultProcessRunner*` tests pass (6 pre-existing + 4 integration tests from gargantua-jgwm) covering natural exit, exit-code surfacing, large payload drain, descendant-inherited fd handling, SIGTERM/SIGKILL escalation, and descendant cleanup after leader exit. Full suite: 461/461 green across 3 consecutive runs.

**Review:** SC (Sonnet → Codex).
- Sonnet pass flagged missing EINTR retry on waitpid → fixed in commit 3ddd3b7.
- Codex pass flagged (a) fd-aliasing with stdio if addclose hits the target fd, (b) pid-reuse window during delayed SIGKILL, (c) silent exit-0 on non-EINTR waitpid failure, (d) ignored `posix_spawn_*` return values, (e) unhandled `strdup` NULL → all fixed in commit b4f09ee.

**Out of scope (noted for follow-up):**
- `POSIX_SPAWN_CLOEXEC_DEFAULT` would tighten fd hygiene for descendants but changes inheritance semantics; deferred.
- The microsecond-wide close-race false-positive timedOut that can still occur when a child exits exactly at the deadline. Impact is minimal (caller sees timedOut instead of natural exit; child is dead either way). Accepted per SC convention of "fix ERRORs, note WARNINGs".
