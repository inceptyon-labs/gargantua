---
# gargantua-c6s7
title: 'Task: Add czkawka_cli adapter and Trust Layer mapping'
status: completed
type: task
priority: high
created_at: 2026-04-17T18:07:38Z
updated_at: 2026-04-17T20:45:55Z
parent: gargantua-0q30
---

Bundle or detect czkawka_cli, run isolated scans for Phase 2 file-health categories, parse output, and map empty/broken/similar/large/corrupt findings to Trust Layer defaults.

## Summary of Changes

Added Phase 2 `CzkawkaAdapter` that wraps the `czkawka_cli` binary, parses per-category output, and maps findings to Trust Layer defaults. The adapter is fully covered by unit tests using a stub process runner so tests don't require czkawka to be installed.

**New files:**
- `Sources/GargantuaCore/Services/CzkawkaBinaryResolver.swift` — Resolves the binary via `GARGANTUA_CZKAWKA_BIN` env var, common PATH install locations, then bundled fallback.
- `Sources/GargantuaCore/Services/CzkawkaOutputParser.swift` — `CzkawkaCategory` enum (8 categories), `CzkawkaFinding` model, and a line-based parser that handles flat output, grouped similar-images/videos, and big-files byte-count prefixes.
- `Sources/GargantuaCore/Services/CzkawkaAdapter.swift` — `ScanAdapter` implementation with injectable `ProcessRunner`, pipe-drain-safe `DefaultProcessRunner`, and `CzkawkaTrustDefaults.builtIn` mapping (empty/broken/temp → safe; big/similar/corrupt → review).

**Tests:** 22 new tests across 3 suites; total suite grew from 250 → 272 (all passing).

**Trust Layer mapping:**
- `.safe`: empty files, empty folders, broken symlinks, temporary files
- `.review`: big files, similar images, similar videos, broken/corrupt files

**Review notes:** Codex second-pass review skipped due to API rate limit (try again after 7:59 PM). Expanded self-review covered concurrency/Sendable, parser edge cases, and lifecycle — no blocking issues found.

**Known limitations / deferred:**
- No `SafetyClassifier` wiring yet — Trust Layer overrides (age-based etc.) are applied at the NativeScanAdapter layer today; Czkawka adapter produces base classifications only. Can be added when Phase 2 UI composes multiple adapters.
- Subcommand names (`big`, `image`, `symlinks`, etc.) match current czkawka_cli 6.x/7.x; older versions used longer names. Parser is lenient enough that output format variations are mostly absorbed.
