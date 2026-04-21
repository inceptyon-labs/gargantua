---
# gargantua-lupo
title: 'Feature: Wire Deep Clean to NativeScanAdapter'
status: completed
type: feature
priority: critical
created_at: 2026-04-17T01:06:43Z
updated_at: 2026-04-21T19:06:46Z
parent: gargantua-l9dk
---

Replace MoCleanAdapter in the Deep Clean view with NativeScanAdapter so Deep Clean produces real results instead of hanging. Covers injection site + adapter construction + profile selection + UI integration.

## Acceptance Criteria
- [x] `MainContentView.swift:44-47` — `DeepCleanView(adapter:)` no longer takes a `MoCleanAdapter`; takes either a `NativeScanAdapter` or an abstraction that both conform to (option A: introduce a `ScanAdapter` protocol, option B: switch DeepCleanView to use NativeScanAdapter directly). Choose before starting.
- [x] `DeepCleanView` surfaces the active `CleanupProfile` (Developer / Light / Deep) via the existing profile selector, passing it into `NativeScanAdapter(profile:)`
- [x] Deep scan UX distinguishes from Quick Scan by using the `.deep` profile and enabling glob walking (depends on glob walker task)
- [x] Existing confirmation modal + `CleanupEngine.clean()` flow continues to work — no changes to post-scan path
- [x] `swift build` clean
- [x] Smoke test: launch app, hit Deep Clean, results appear, confirm, items moved to Trash, audit entry written

## Wiring Checklist
- [x] Decide adapter abstraction (protocol vs. direct) and document choice
- [x] Update `MainContentView.swift:44-47` call site
- [x] Update `DeepCleanView.swift` init signature + @State storage
- [x] Update `DeepCleanView` scan trigger to call `NativeScanAdapter.scan(progress:)`
- [x] Thread through selected `CleanupProfile` from Settings / ProfileContainerView
- [x] Load rules via `RuleLoader` + `RuleDirectoryResolver` (extract helper if duplicated from DashboardView)
- [x] Delete / deprecate `MoCleanAdapter` once no callers remain
- [x] Remove `MoCleanAdapter` references from `MoCleanAdapterTests` or repoint tests at `NativeScanAdapter`

## Out of Scope
- Glob walking (blocked by sibling task)
- Settings UI for picking scan rules


## Progress (2026-04-16)

### Decision: Protocol abstraction
Introduced `ScanAdapter` protocol in `Sources/GargantuaCore/Services/ScanAdapter.swift`. `NativeScanAdapter` now conforms. `DeepCleanView` holds an optional injected `any ScanAdapter` (for tests) but defaults to building a `NativeScanAdapter` via the new `NativeScanAdapter.loadDefaults(profile:)` factory that does the rule-loading dance. This DRY'd out the same dance in `DashboardView.startQuickScan`.

### Files Changed
- Sources/GargantuaCore/Services/ScanAdapter.swift (new — protocol + error type)
- Sources/GargantuaCore/Services/NativeScanAdapter.swift — conforms to ScanAdapter, adds `loadDefaults(profile:)` static factory
- Sources/GargantuaCore/Views/DeepCleanView.swift — drops MoCleanAdapter dependency, takes `profile: CleanupProfile = .deep`, constructs adapter on scan, surfaces errors through scanProgress
- Sources/GargantuaCore/Views/DashboardView.swift — refactored to call `NativeScanAdapter.loadDefaults(profile: .light)`
- Sources/Gargantua/MainContentView.swift — `DeepCleanView(profile: .deep)` replaces MoCleanAdapter construction

### Verification
- `swift build` clean
- `swift test` — 265 tests, 37 suites, all passing (MoCleanAdapter tests untouched — adapter still exists, just unused by views)
- [x] Live smoke test in running app (completed by `gargantua-i6ev`)

### Updated Acceptance Criteria
- [x] `MainContentView.swift` no longer passes MoCleanAdapter to DeepCleanView
- [x] DeepCleanView uses `CleanupProfile.deep` by default — profile is now the injection point, not the adapter
- [x] `ScanAdapter` protocol introduced — future swap/test injection ready
- [x] Rule-loading DRY'd into `NativeScanAdapter.loadDefaults(profile:)`
- [x] Existing confirmation modal + CleanupEngine flow unchanged
- [x] `swift build` clean
- [x] Live smoke test
- [x] Profile threaded from user-selected profile
- [x] Glob walking for `**/` patterns — completed by gargantua-avik

### Remaining
- None. Follow-up work completed the stale profile-threading, glob-walking, and live-smoke gates.

## Completion (2026-04-21)

Closed after verifying the later follow-up work completed the remaining gates:

- `MainContentView.activeDeepCleanProfile` now reads persisted settings, resolves custom or built-in profiles, and passes the active profile into `DeepCleanView`.
- `DeepCleanView.startScan()` uses `NativeScanAdapter.loadDefaults(profile:)`; Quick Scan still uses `.light`, while Deep Clean defaults to `.deep` and can receive the persisted active profile.
- `MoCleanAdapter`, `MoPurgeAdapter`, `MoleRunner`, and their tests have been removed by `gargantua-2xrw` / `gargantua-gf5w`; no production or test references remain.
- `gargantua-i6ev` recorded the live app smoke: Deep Clean returned NativeScanAdapter results, cleanup moved a selected item to Trash, and the audit log recorded the cleanup.

Verification:
- `swift test` passed on 2026-04-21: 848 tests across 107 suites.
- Worktree had no source changes for this closeout; this bean was stale bookkeeping after the code and smoke gates had already landed.
