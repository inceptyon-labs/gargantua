---
# gargantua-gcf8
title: Harden DefaultProcessRunner against pipe-fd inheritance and SIGTERM-ignoring children
status: completed
type: task
priority: low
created_at: 2026-04-18T13:16:14Z
updated_at: 2026-04-18T19:52:18Z
parent: gargantua-qe4a
---

Codex flagged two pre-existing weaknesses in DefaultProcessRunner that this task's drain refactor did not address:

1. `readDataToEndOfFile()` blocks until every writer to the pipe closes it. If the child forks a descendant that inherits stdout/stderr (e.g. `sh -c 'sleep 999 &'`), the pipe fd stays open and `drainGroup.wait()` can hang indefinitely after the child exits.

2. Timeout path only calls `process.terminate()` (SIGTERM). A process that ignores/traps SIGTERM, or whose descendant holds the pipe, can cause `run(timeout:)` to block forever while still being reported as timed out.

Both predate the 2g77 refactor. Current adapters (czkawka_cli, fclones) are well-behaved CLIs so this hasn't caused observed problems, but hardening is worth doing.

Scope:
- [x] Use process group (setpgid) so we can signal descendants
- [x] Escalate timeout from SIGTERM → SIGKILL after bounded grace period
- [x] Bounded `drainGroup.wait()` (e.g. with DispatchSemaphore + small grace) after timeout/exit; close pipe fds if drain doesn't finish
- [x] Add integration tests covering descendant-inherited-fd and SIGTERM-ignoring cases

Related: gargantua-2g77 (original drain refactor), gargantua-jgwm (real-process integration tests).

Implementation complete. Hardened DefaultProcessRunner against inherited-fd hangs and SIGTERM resistance. Used process groups and signal escalation (SIGTERM → SIGKILL). Added bounded drain wait with fd closure on timeout. Added 4 new integration tests covering both scenarios. All 456 tests pass.


## Summary of Changes

- Put the child in its own process group (`setpgid`) and signal the whole group with `killpg`, falling back to per-PID signals when group setup fails.
- Escalate SIGTERM → SIGKILL after a 0.5 s grace, and in the pgid path escalate unconditionally so a descendant that outlives a TERM-exiting leader is still reaped.
- Bounded `drainGroup.wait()` with a 0.1 s floor / 1 s ceiling; on timeout, force-close the read fds and wait briefly for the drain tasks to exit.
- Switched blocking reads to `readToEnd()` so force-closing the fd surfaces as a Swift error rather than an NSException crash.
- Added integration tests for inherited-fd, TERM-ignoring, leader-exits-descendant-traps-TERM, and timeout boundary cases with wall-clock assertions.

Limitation: `setpgid` is still post-spawn via `Foundation.Process`, which can race a child that forks descendants before the parent call runs. A proper fix would require `posix_spawn(POSIX_SPAWN_SETPGROUP)`, which `Foundation.Process` doesn't expose; deferred as a follow-up.

Commits: da0c3b6 (initial implementation), 5f37f64 (Codex review fixes).
