---
# gargantua-566u
title: Use posix_spawn(POSIX_SPAWN_SETPGROUP) to close setpgid race in DefaultProcessRunner
status: todo
type: task
priority: low
created_at: 2026-04-18T19:52:30Z
updated_at: 2026-04-18T19:52:36Z
parent: gargantua-qe4a
---

Follow-up from gargantua-gcf8. Current implementation calls `setpgid` on the child from the parent after `process.run()`, which is inherently racy: a child that forks descendants before the parent's `setpgid` runs will leave those descendants in the parent's group rather than the child's. `Foundation.Process` doesn't expose pre-exec hooks, so closing the race requires replacing (or wrapping) `Foundation.Process` with a direct `posix_spawn` call using `POSIX_SPAWN_SETPGROUP`.

Scope:
- [ ] Wrap `posix_spawn` in a minimal Swift helper that matches `DefaultProcessRunner`'s needs (exec + args + pipes)
- [ ] Migrate `DefaultProcessRunner.run` to the helper, preserving existing timeout/drain/escalation behavior
- [ ] Remove the post-spawn `setpgid` and its `hasPgid` fallback
- [ ] Keep (or update) existing integration tests; they should continue to pass
- [ ] Consider whether the same pattern belongs in a shared `ProcessSpawner` primitive

Related: gargantua-gcf8 (initial hardening), gargantua-2g77 (drain refactor).
