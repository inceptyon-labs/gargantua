# Session Handoff: Wire Dev Purge to NativeScanAdapter
Date: 2026-04-16
Epic: gargantua-l9dk - Phase 1.5 Native Scanner Cutover
Completed feature: gargantua-guga - Wire Dev Purge to native dev-artifact scanner

## What Was Done This Session

1. **Completed gargantua-guga** — Dev Artifact Purge view now runs `NativeScanAdapter.loadDefaults(profile: .devPurge, scanRoots:)` instead of `MoPurgeAdapter`. Mirrors the lupo Deep Clean pattern; `any ScanAdapter` injection point preserved for tests.

2. **Introduced `CleanupProfile.devPurge`** — scoped strictly to `dev_artifacts`, `docker`, `homebrew`. `.developer` was the initial choice; Codex SC review caught that it would pull in browser/system/temp rules. Now Dev Purge cannot silently widen scope.

3. **Added `PersistedSettings.scanRoots: [String]`** — SwiftData-persisted project roots (parity with `mo purge --paths`). Empty array = use `PathExpander.defaultScanRoots()`. MainContentView validates stored entries (empty, `/`, `~` dropped).

4. **Hardened `PathExpander.defaultScanRoots()`** — returns `[]` instead of `[home]` when no preferred project root exists. The old fallback would silently walk the entire home directory.

5. **Walker-cap warnings now surface in `resultsView`** — previously partial scans looked complete because `scanProgress.errors` only rendered on the pre-scan footer.

6. **Removed Python/Rust/Go category rows** from `DevArtifactScanView` — no corresponding native YAML rules exist (only node/xcode/docker/homebrew). Follow-up bean `gargantua-sdhp` tracks re-adding them once rules exist.

7. **Codex SC review findings** — all four ERROR/WARNING items fixed before merge (wrong profile, stale categories, unsafe defaultScanRoots fallback, missing scan-root validation).

8. **Filed follow-ups** under epic `gargantua-l9dk`:
   - `gargantua-sdhp` — Add Python/Rust/Go YAML rules
   - `gargantua-0ugr` — Settings UI for scan roots
   - `gargantua-t114` — NativeScanAdapter integration tests
   - `gargantua-zq15` — `lastAccessed` uses modificationDate (semantic bug)

9. **Cleared stale blocker** on guga (blocked_by `gargantua-9hhj` was backwards — guga resolves 9hhj, not the other way around).

## Current State

- Branch: `main` — merge commit `719a812`
- Tests: 276/276 passing (added 1 for `CleanupProfile.devPurge` + assertions on `PersistedSettings.scanRoots`)
- Build: clean
- Lint: 0 serious; 2 accepted stylistic warnings on `DevArtifactScanView` (file_length, type_body_length) matching the pattern accepted for `PathExpander`
- Live smoke test: **pending user run** — open app → Dev Artifact Purge → Scan Selected Categories → confirm results include at least one `node_modules` on this machine

## Next Steps (ordered)

1. **gargantua-lupo** — live smoke test Deep Clean in the running app (user-driven, coded last session)
2. **gargantua-guga** — live smoke test Dev Purge in the running app (user-driven, coded this session)
3. **gargantua-2xrw** — Delete or gate `MoCleanAdapter` + `MoPurgeAdapter`. Both views have now been cut over (lupo + guga complete); adapters have no view callers. Tests exist for the adapters themselves; decide delete vs. `@available(*, deprecated)`.
4. **gargantua-gf5w** — Bundle `cleanup_rules/` into shipped `.app` + decide `mo` binary strategy for release (still outstanding from prior session)
5. **gargantua-9hhj** — once 2xrw removes the adapters, close as fixed by the cutover
6. **gargantua-sdhp** — Add Python/Rust/Go YAML rules so those Dev Purge categories come back
7. **gargantua-0ugr** — Settings UI for editing `PersistedSettings.scanRoots`
8. **gargantua-t114** — NativeScanAdapter integration tests (cap warnings, dedup, profile scoping, `rule.pattern` filtering)
9. **gargantua-zq15** — Fix `lastAccessed` semantics in `NativeScanAdapter.makeResult`
10. **gargantua-y1zi** — Diagnose Disk Explorer (not blocked by cutover, separate failure mode)
11. **Follow-ups surfaced by earlier avik Codex review** (still unfilled, from prior handoff):
    - Bounded/cancellable sizing in `DirectorySizeScanner.directorySize`
    - Walker-level exclude pruning
    - Hidden-file handling policy for `.venv`, `.gradle`, `.next`
    - Streaming child enumeration for million-entry dirs
    - `..` normalization

## Files to Load Next Session

- `.beans/gargantua-l9dk--epic-phase-15-native-scanner-cutover.md` — epic scope
- `.beans/gargantua-2xrw--task-add-scanadapter-protocol-or-remove-mocleanada.md` — next bean to kick
- `Sources/GargantuaCore/Services/MoCleanAdapter.swift` + `MoPurgeAdapter.swift` — deletion candidates
- `Tests/GargantuaCoreTests/Services/MoCleanAdapterTests.swift` + `MoPurgeAdapterTests.swift` — decide fate with adapters
- `Sources/GargantuaCore/Services/ScanAdapter.swift` — protocol already in place

## What NOT to Re-Read

- `DevArtifactScanView.swift` — fully cut over, covered by this handoff
- `NativeScanAdapter.swift` — only a `loadDefaults(profile:scanRoots:)` overload was added
- `PathExpander.swift` — only the `defaultScanRoots()` home fallback was tightened
- `MainContentView.swift` — `devPurge` case + `resolvedScanRoots` helper fully described here
- Previous-session files already described in `docs/handoffs/archive/handoff-2026-04-16-bounded-glob-walker.md`
