---
# gargantua-2g77
title: Harden DefaultProcessRunner pipe draining against handler/readToEOF race
status: todo
type: task
priority: low
created_at: 2026-04-17T21:12:38Z
updated_at: 2026-04-17T21:12:38Z
parent: gargantua-qe4a
---

Current DefaultProcessRunner.run() installs a readability handler that appends each chunk to a shared buffer, then after waitUntilExit nils the handler and calls readDataToEndOfFile() to drain the tail. Apple's docs are ambiguous about whether setting the handler to nil blocks for in-flight invocations, so a handler chunk racing with readDataToEndOfFile() can in principle produce interleaved or duplicated bytes.

Pre-existing from the CzkawkaAdapter lineage and has not caused observed problems, but flagged in the fclones SC review (Pass 2). Cleanup: switch to a single-path drain — either handler-only with an EOF sentinel (empty-chunk detection) or a dedicated blocking-read DispatchQueue per pipe that join()s after waitUntilExit. Add a test that forks /bin/echo of a large payload and asserts byte-for-byte stdout capture to exercise the path.

Scope:
- [ ] Decide on drain strategy (handler-EOF vs background blocking-read)
- [ ] Refactor DefaultProcessRunner accordingly
- [ ] Add real-Process test for large-stdout capture
- [ ] Verify Czkawka and fclones adapters still pass unchanged
