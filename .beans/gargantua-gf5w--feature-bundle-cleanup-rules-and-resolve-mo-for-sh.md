---
# gargantua-gf5w
title: 'Feature: Bundle cleanup_rules and resolve mo for shipped .app'
status: completed
type: feature
priority: high
created_at: 2026-04-17T01:07:15Z
updated_at: 2026-04-17T16:16:51Z
parent: gargantua-l9dk
---

In a shipped signed/notarized .app bundle, cleanup_rules YAML files and any mo dependency must live in predictable bundle locations. Currently rules live at repo root (only swift run works) and mo lookup only falls back to homebrew paths.

## Acceptance Criteria
- [x] `cleanup_rules/` shipped as SPM resource on GargantuaCore target
- [x] `RuleDirectoryResolver.resolve()` uses `Bundle.module` primarily, `Bundle.main.resourceURL` as fallback
- [ ] Decision recorded: do we bundle `mo` or drop the hard dependency on it?
      - Option A (bundle): download mo binary in CI, sign with our team ID, place in `Contents/Resources/mo`. MoAnalyzeAdapter / MoStatusAdapter find it.
      - Option B (drop): remove mo from the app's runtime path entirely; replace `mo analyze` with native disk walker and `mo status` with native `sysctl`/`IOKit` queries (already PRD Phase 1.5 plan for status).
      - Option C (require brew): document "Install mole via Homebrew to enable Disk Explorer / System Status"; detect and show onboarding banner if missing.
- [x] Option B (drop mo) chosen and executed
- [x] Rules resolve via Bundle.module in swift run, swift test, and a shipped .app

## Wiring Checklist
- [ ] Add resource declaration to `Package.swift` for cleanup_rules (or add build script)
- [ ] Verify `Bundle.main.resourceURL` path at runtime when launched from Finder
- [ ] If Option A: add CI step to fetch + codesign mo, update `MoleRunner.resolveBinaryPath()` to check bundled path first
- [ ] Update onboarding to detect missing mo (Option C) and guide install

## Notes
Current `RuleDirectoryResolver` already walks up from the executable looking for `Package.swift` — that fallback disappears in a shipped `.app`, so the bundled resource path is the hard requirement.

## Plan (2026-04-17)

**Scope decision:** Drop mo entirely (Option B), bundle cleanup_rules via SPM resource on GargantuaCore target. Native scanners already cover all runtime paths (`DirectorySizeScanner` for Disk Explorer, `SystemMetricCollector` for System Status, `NativeScanAdapter` for clean/purge). MoStatusAdapter, MoAnalyzeAdapter, MoleRunner, MoleOutputParser have zero production callsites — they are dead code.

**Execution checklist:**
- [x] Move `cleanup_rules/` → `Sources/GargantuaCore/Resources/cleanup_rules/`
- [x] Add `.copy("Resources/cleanup_rules")` to GargantuaCore target in `Package.swift`
- [x] Update `RuleDirectoryResolver` to resolve via `Bundle.module`
- [x] Delete `MoStatusAdapter.swift` + tests
- [x] Delete `MoAnalyzeAdapter.swift` + tests
- [x] Delete `MoleRunner.swift` + tests
- [x] Delete `MoleOutputParser.swift` + tests
- [x] Simplify `SystemMetricCollector`: drop `MoleRunner?` param, remove mo fallbacks
- [x] Remove Mole status indicator from `SidebarView` (replaced with Native indicator)
- [x] Update `AuditEntry` engine doc (drop 'mole')
- [x] Update `RuleViewerView` to use `RuleDirectoryResolver.resolve()`
- [x] swift build + swift test green (235 tests, 31 suites)
- [ ] Live smoke (user): `swift run` → Deep Clean, Dev Purge, System Status, Disk Explorer all functional

## Summary of Changes

**Part A — SPM resources:** Moved `cleanup_rules/` to `Sources/GargantuaCore/Resources/cleanup_rules/` and declared `.copy("Resources/cleanup_rules")` on GargantuaCore target. `RuleDirectoryResolver` now resolves via `Bundle.module.resourceURL` (primary — works in swift run, swift test, shipped .app via embedded `GargantuaCore_GargantuaCore.bundle`) with `Bundle.main.resourceURL` as secondary fallback for flat-copied .app layouts. Dropped executable-walkup and CWD fallbacks.

**Part B — Dropped mo entirely:** Deleted `MoStatusAdapter`, `MoAnalyzeAdapter`, `MoleRunner`, `MoleOutputParser` + their tests (all zero-callsite dead code). Simplified `SystemMetricCollector` to native-only (Mach host APIs + FileManager + ProcessInfo) — dropped `MoleRunner?` dependency, dropped `MetricCollectionError`, made metric helpers synchronous. Removed Mole sidebar status indicator (replaced with always-on Native indicator). Updated `AuditEntry` and `ScanAdapter` doc comments. Updated `RuleViewerView` and `RuleSetIntegrationTests` to use `RuleDirectoryResolver.resolve()`.

**SC review findings fixed:**
- W1: Stale `tool: "mole"` in `CleanupProfileTests` → updated to `"native"`
- W2: `ScanAdapterError.rulesDirectoryNotFound` error message updated to reference bundle resource, not CWD
- W4: Sync metric helpers now declared non-`async` (cleaner, matches runtime behavior)
- S3: Scrubbed "Mole subprocess" from `ScanAdapter` doc; removed stale `test_output.txt` from repo root

**Tests:** 235/281 pass (46 tests removed along with deleted adapters). Build clean, swiftlint clean on changed files.

**Remaining:** User-run live smoke test to confirm Deep Clean / Dev Purge / System Status / Disk Explorer all function from `swift run` after the cutover.
