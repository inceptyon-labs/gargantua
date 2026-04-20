---
# gargantua-1vbh
title: Bound captured stdout/stderr in DefaultProcessRunner
status: in-progress
type: task
priority: low
created_at: 2026-04-20T01:24:49Z
updated_at: 2026-04-20T01:27:13Z
parent: gargantua-qe4a
---

ProcessRunner.swift:~121 reads subprocess stdout/stderr into in-memory buffers with no byte cap. A misbehaving or malicious binary can flood either stream before the timeout fires and drive Gargantua into memory pressure (watchOS-style OOM isn't a thing on macOS, but the user-visible symptom is beachball + spiking RSS before the timeout trips).

Fix:
- Add a `maxCapturedBytes` parameter (default e.g. 1 MiB) to ProcessRunner.run.
- On the drain path, truncate writes past the cap and record a `stdoutTruncated` / `stderrTruncated` flag on ProcessOutput so callers know the capture is incomplete.
- Wire through DeveloperToolPreviewAdapter and CzkawkaAdapter/FclonesAdapter: 1 MiB is fine for brew cleanup and docker system df; the scan adapters may need more, so let them pass an override.

Tests:
- DefaultProcessRunner: a subprocess that prints > cap to stdout returns truncated output + flag set, no deadlock.
- Same for stderr.
- Existing timeout and pipe-fd tests still pass.

Surfaced during gargantua-apnw review (Codex SC pass, 2026-04-19). Related hardening: gargantua-gcf8 (pipe-fd inheritance), gargantua-eom1 (drain-grace starvation).
