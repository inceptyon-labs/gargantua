---
# gargantua-i1ii
title: 'Task: Add fclones adapter and JSON parser'
status: completed
type: task
priority: high
created_at: 2026-04-17T18:07:38Z
updated_at: 2026-04-17T21:12:25Z
parent: gargantua-4nb9
---

Bundle or detect fclones, run isolated Process with timeout, parse JSON output, and map duplicate groups into review-by-default scan results.


## Summary of Changes

Implemented `FclonesAdapter` conforming to `ScanAdapter`, mirroring the pattern established by the just-merged `CzkawkaAdapter`.

**New files**
- `Sources/GargantuaCore/Services/FclonesBinaryResolver.swift` — locates `fclones` via `GARGANTUA_FCLONES_BIN`, Homebrew paths, or bundled Resources fallback.
- `Sources/GargantuaCore/Services/FclonesOutputParser.swift` — Codable-based parser for fclones's `{header, groups}` JSON using snake_case key decoding. Filters single-path groups defensively.
- `Sources/GargantuaCore/Services/FclonesAdapter.swift` — `scan(progress:)` runs `fclones group --format json <roots>` under a configurable wall-clock timeout (default 10 minutes), maps each duplicate path to a `ScanResult` with `.review` safety per PRD §7, and tags results by group + short hash. Reclaimable bytes computed as (N − 1) × fileLen per group, overflow-clamped at Int64.max.
- `Sources/GargantuaCore/Services/ProcessRunner.swift` — extracted from `CzkawkaAdapter.swift` (now shared by two adapters) and extended with a timeout variant. `DefaultProcessRunner` uses a `TimeoutCoordinator` (single-lock state machine) to safely decide between natural exit and watchdog-triggered termination — closes the race where `DispatchWorkItem.cancel()` can't stop an already-executing block.
- Three new test files (21 tests total) covering resolver, parser, and adapter including: timeout forwarding, group tag mapping, path dedupe, empty-scanRoots short-circuit, reclaimable-bytes math, parse failure, non-zero exit handling.

**Tests**: 293/293 passing (up from 272 baseline; +21 new fclones tests).
**Lint**: all new files clean; remaining project warnings are pre-existing and unrelated.
**Review**: SC-tier cascading review (Sonnet → independent Opus pass; Codex was rate-limited) caught and fixed a reclaimable-bytes overcount, a timeout-detection race, an empty-scanRoots silent-CWD-scan, and an overflow trap on malicious `file_len`. All resolved in-branch.
