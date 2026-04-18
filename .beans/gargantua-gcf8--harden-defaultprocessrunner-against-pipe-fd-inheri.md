---
# gargantua-gcf8
title: Harden DefaultProcessRunner against pipe-fd inheritance and SIGTERM-ignoring children
status: todo
type: task
priority: low
created_at: 2026-04-18T13:16:14Z
updated_at: 2026-04-18T13:16:14Z
parent: gargantua-qe4a
---

Codex flagged two pre-existing weaknesses in DefaultProcessRunner that this task's drain refactor did not address:

1. `readDataToEndOfFile()` blocks until every writer to the pipe closes it. If the child forks a descendant that inherits stdout/stderr (e.g. `sh -c 'sleep 999 &'`), the pipe fd stays open and `drainGroup.wait()` can hang indefinitely after the child exits.

2. Timeout path only calls `process.terminate()` (SIGTERM). A process that ignores/traps SIGTERM, or whose descendant holds the pipe, can cause `run(timeout:)` to block forever while still being reported as timed out.

Both predate the 2g77 refactor. Current adapters (czkawka_cli, fclones) are well-behaved CLIs so this hasn't caused observed problems, but hardening is worth doing.

Scope:
- [ ] Use process group (setpgid) so we can signal descendants
- [ ] Escalate timeout from SIGTERM → SIGKILL after bounded grace period
- [ ] Bounded `drainGroup.wait()` (e.g. with DispatchSemaphore + small grace) after timeout/exit; close pipe fds if drain doesn't finish
- [ ] Add integration tests covering descendant-inherited-fd and SIGTERM-ignoring cases

Related: gargantua-2g77 (original drain refactor), gargantua-jgwm (real-process integration tests).
