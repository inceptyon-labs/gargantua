---
# gargantua-1vbh
title: Bound captured stdout/stderr in DefaultProcessRunner
status: completed
type: task
priority: low
created_at: 2026-04-20T01:24:49Z
updated_at: 2026-04-20T01:40:32Z
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


## Summary of Changes

Bounded subprocess stdout/stderr capture in `DefaultProcessRunner` to prevent memory pressure from a misbehaving or malicious binary.

### Changes

**`ProcessRunner.swift`**
- New protocol overload: `run(executable:arguments:timeout:maxCapturedBytes:)`. Default extension delegates to the timeout-only variant so existing conforming types (stubs) remain source-compatible.
- `ProcessOutput` gains `stdoutTruncated` / `stderrTruncated` flags with default-false initializers.
- `DataBuffer` is now cap-aware: retains up to `limit` bytes, drops the rest, records a truncated flag.
- Drain loop swapped from `readToEnd()` (which buffers everything in memory and defeats the cap) to chunked `read(upToCount: 16 * 1024)` calls. Bytes past the cap are still pulled from the pipe so the child never blocks on a full kernel buffer.
- Decode uses `String(decoding:as: UTF8.self)` instead of `String(data:encoding:)` so a cap that slices a multi-byte codepoint yields U+FFFD in place of an empty string.
- `DefaultProcessRunner.defaultMaxCapturedBytes = 1 MiB`.

**Adapter wiring**
- `DeveloperToolPreviewAdapter`: passes 1 MiB explicitly at both call sites (version check, preview).
- `FclonesAdapter`: 64 MiB override (`scanCaptureLimit`). On truncation, surfaces a distinct "output exceeded cap" diagnostic and aborts the scan (JSON would be unbalanced anyway).
- `CzkawkaAdapter`: 64 MiB override. On truncation, records a non-fatal warning and trims the trailing partial line via `trimTrailingPartialLine(_:)` so a mid-line slice can't fabricate a finding.

### Tests added (6)

`DefaultProcessRunnerTests`:
- stdout past cap is truncated + flagged, no deadlock
- stderr past cap is truncated + flagged independently
- both streams truncate simultaneously with independent flags
- multi-byte UTF-8 codepoint slice preserves the prefix
- output within cap is not flagged

`CzkawkaAdapterTests`:
- truncated output trims final partial line and records a warning

All 711 tests pass. Build/lint/verification clean.

### Review

SC cascade: Sonnet (clean, no errors), then Codex. Sonnet surfaced the UTF-8 decode edge case and missing multi-stream coverage. Codex surfaced a real issue with mid-line path slicing in czkawka output that could fabricate findings — addressed with `trimTrailingPartialLine`. Codex also noted ProcessSpawner env/fd inheritance (out of scope here; tracked as gargantua-gcf8) and waitpid-failure cleanup (rare edge case, deferred).

Commits: 9db2c8c, 01f6dc7, 1e97e34.
