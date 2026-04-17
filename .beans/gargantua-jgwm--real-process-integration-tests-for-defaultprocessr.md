---
# gargantua-jgwm
title: Real-Process integration tests for DefaultProcessRunner timeout path
status: todo
type: task
priority: low
created_at: 2026-04-17T21:12:44Z
updated_at: 2026-04-17T21:12:44Z
parent: gargantua-qe4a
---

Current ProcessRunner tests only use StubRunner implementations that return canned ProcessOutput. The timeout watchdog, AtomicFlag coordination, and pipe draining in DefaultProcessRunner itself are entirely uncovered by tests. The fclones SC review Pass 2 flagged this as a warning.

Add a small integration-test suite that forks real /bin/sh commands:
- [ ] /bin/sleep 5 with timeout: 0.2 → expect ProcessRunnerError.timedOut
- [ ] /bin/echo "hello" with no timeout → expect stdout == "hello\n"
- [ ] /bin/sh -c "exit 7" → expect exitCode == 7
- [ ] Large-payload /bin/sh -c "yes | head -c 100000" → expect no deadlock and full capture

Keep wall-clock short (<1s each) so they don't slow CI. These tests belong under Tests/GargantuaCoreTests/Services/DefaultProcessRunnerIntegrationTests.swift or similar.
