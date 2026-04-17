# Session Handoff: Drop mo, Bundle cleanup_rules
Date: 2026-04-17
Beans completed: gargantua-gf5w, gargantua-9hhj, gargantua-2xrw

## What Was Done This Session

1. **Closed gargantua-9hhj + gargantua-2xrw** — deleted `MoCleanAdapter.swift`, `MoPurgeAdapter.swift`, and their test files. Production callsites had already been cut over by `gargantua-lupo` (Deep Clean) and `gargantua-guga` (Dev Purge), so this was pure dead-code removal. Scrubbed stale `MoCleanAdapter.scan` reference from `NativeScanAdapter.swift`. 281 tests passing before this point.

2. **Closed gargantua-gf5w** — two-part feature:

   **Part A — SPM resources:** Moved `cleanup_rules/` from repo root to `Sources/GargantuaCore/Resources/cleanup_rules/`. Declared `.copy("Resources/cleanup_rules")` on the GargantuaCore target in `Package.swift`. Rewrote `RuleDirectoryResolver.resolve()` to use `Bundle.module.resourceURL` (primary — works for `swift run`, `swift test`, and a shipped `.app` that embeds `GargantuaCore_GargantuaCore.bundle`) with `Bundle.main.resourceURL` as a secondary fallback. Dropped the old executable-walkup and CWD probes.

   **Part B — Dropped mo entirely:** Deleted `MoStatusAdapter.swift`, `MoAnalyzeAdapter.swift`, `MoleRunner.swift`, `MoleOutputParser.swift` and their tests (all zero-callsite dead code — `DiskExplorerView` uses `DirectorySizeScanner`, `DashboardView` uses `SystemMetricCollector`, nothing else referenced mo). Simplified `SystemMetricCollector`: dropped `MoleRunner?` dep, removed all `*FromMoStatus` fallbacks, removed `MetricCollectionError` enum, made metric helpers synchronous (they are all fast Mach/FileManager calls — `async let` was a lie), kept `collect()` async for caller compatibility. Replaced Mole sidebar status indicator with always-on "Native" indicator. Scrubbed stale `"mole"` from `AuditEntry` doc and `CleanupProfileTests` round-trip. Updated `RuleViewerView` to use `RuleDirectoryResolver.resolve()` instead of its own `Bundle.main` probe.

3. **SC review done** — self-pass found no blockers; code-reviewer subagent pass identified 4 real findings:
   - W1: Stale `tool: "mole"` in `CleanupProfileTests` → updated to `"native"`
   - W2: `ScanAdapterError` error message referenced CWD (stale post-resolver-rewrite) → now references bundle resource
   - W4: Metric helpers were `async` but never awaited → dropped `async`
   - S3: `ScanAdapter` doc said "Mole subprocess" as alternative backend → dropped; `test_output.txt` stale artifact at repo root → removed

## Current State

- Branch: `main` — merge commit `0b88f6b` (with feature commit `f2f6aba`)
- Tests: 235/235 passing (down from 281 — 46 tests removed with deleted adapters)
- Build: clean
- Lint: changed files clean; pre-existing warnings on `RuleViewerView.swift` (whitelist/inclusive-language, file length) untouched
- Live smoke test: **pending user run** — `swift run Gargantua` → Deep Clean / Dev Purge / System Status / Disk Explorer all functional after mo removal

## Next Steps (ordered)

1. **gargantua-lupo** — live smoke test Deep Clean (still formally in-progress pending user verification)
2. **gargantua-guga / gargantua-y1zi** — live smoke tests for Dev Purge + Disk Explorer (previously flagged; still user-driven)
3. **gargantua-gf5w** — live smoke test of the whole app post-mo-drop (user; flip last checkbox when verified)
4. **gargantua-sdhp** — Add Python/Rust/Go YAML cleanup rules for Dev Purge (normal priority)
5. **gargantua-0ugr** — Settings UI for `PersistedSettings.scanRoots`
6. **gargantua-t114** — NativeScanAdapter integration tests
7. **gargantua-zq15** — Fix `lastAccessed` semantics in `NativeScanAdapter.makeResult` (uses modificationDate, should use access time)
8. **gargantua-evdi** — Bounded/cancellable `directorySize` for Disk Explorer
9. Pre-existing avik Codex follow-ups (still unfiled): walker-level exclude pruning, hidden-file policy, streaming child enumeration for million-entry dirs, `..` normalization

## Files to Load Next Session

- `Sources/GargantuaCore/Services/NativeScanAdapter.swift` — `makeResult` is where zq15 lives (`lastAccessed` field)
- `Sources/GargantuaCore/Parsing/` — sdhp adds YAML rules; RuleLoader is here
- `Sources/GargantuaCore/Views/SettingsView.swift` — 0ugr extends this view
- `.beans/gargantua-{zq15,sdhp,evdi,t114,0ugr}--*.md` — the next candidates

## What NOT to Re-Read

- `SystemMetricCollector.swift` / `RuleDirectoryResolver.swift` / `SidebarView.swift` / `DashboardView.swift` — fully described above; no open questions
- `Package.swift` — SPM resource wiring is complete; only touch if adding more targets/resources
- Deleted mo adapters and tests — they are gone, nothing to load
- `cleanup_rules/` at repo root — **it no longer exists there**, rules live at `Sources/GargantuaCore/Resources/cleanup_rules/`

## Notes for Next Session

- `Bundle.module` is now the canonical way to locate rules in-process. Do NOT reintroduce `Bundle.main.resourceURL/cleanup_rules` as the primary path — `Bundle.main` only works for flat-copied .app layouts.
- `ScanAdapter` protocol has one conformer (`NativeScanAdapter`). Adding a second conformer (e.g. fclones, czkawka) is a future expansion — no urgency.
- `SystemMetricCollector.collect()` is `async` but does no actual awaiting. Fine for now; if we add a metric that genuinely blocks (e.g. disk-backed history), bring back `async let` intentionally.
- `SidebarView` still references "Native" in the engine dot. If the MCP work ever lands, that's where the second dot goes.
