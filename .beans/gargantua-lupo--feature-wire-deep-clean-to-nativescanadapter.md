---
# gargantua-lupo
title: 'Feature: Wire Deep Clean to NativeScanAdapter'
status: in-progress
type: feature
priority: critical
created_at: 2026-04-17T01:06:43Z
updated_at: 2026-04-17T18:07:52Z
parent: gargantua-l9dk
---

Replace MoCleanAdapter in the Deep Clean view with NativeScanAdapter so Deep Clean produces real results instead of hanging. Covers injection site + adapter construction + profile selection + UI integration.

## Acceptance Criteria
- [ ] `MainContentView.swift:44-47` — `DeepCleanView(adapter:)` no longer takes a `MoCleanAdapter`; takes either a `NativeScanAdapter` or an abstraction that both conform to (option A: introduce a `ScanAdapter` protocol, option B: switch DeepCleanView to use NativeScanAdapter directly). Choose before starting.
- [ ] `DeepCleanView` surfaces the active `CleanupProfile` (Developer / Light / Deep) via the existing profile selector, passing it into `NativeScanAdapter(profile:)`
- [ ] Deep scan UX distinguishes from Quick Scan by using the `.deep` profile and enabling glob walking (depends on glob walker task)
- [ ] Existing confirmation modal + `CleanupEngine.clean()` flow continues to work — no changes to post-scan path
- [ ] `swift build` clean
- [ ] Smoke test: launch app, hit Deep Clean, results appear, confirm, items moved to Trash, audit entry written

## Wiring Checklist
- [ ] Decide adapter abstraction (protocol vs. direct) and document choice
- [ ] Update `MainContentView.swift:44-47` call site
- [ ] Update `DeepCleanView.swift` init signature + @State storage
- [ ] Update `DeepCleanView` scan trigger to call `NativeScanAdapter.scan(progress:)`
- [ ] Thread through selected `CleanupProfile` from Settings / ProfileContainerView
- [ ] Load rules via `RuleLoader` + `RuleDirectoryResolver` (extract helper if duplicated from DashboardView)
- [ ] Delete / deprecate `MoCleanAdapter` once no callers remain
- [ ] Remove `MoCleanAdapter` references from `MoCleanAdapterTests` or repoint tests at `NativeScanAdapter`

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
- [ ] Live smoke test in running app (pending user try)

### Updated Acceptance Criteria
- [x] `MainContentView.swift` no longer passes MoCleanAdapter to DeepCleanView
- [x] DeepCleanView uses `CleanupProfile.deep` by default — profile is now the injection point, not the adapter
- [x] `ScanAdapter` protocol introduced — future swap/test injection ready
- [x] Rule-loading DRY'd into `NativeScanAdapter.loadDefaults(profile:)`
- [x] Existing confirmation modal + CleanupEngine flow unchanged
- [x] `swift build` clean
- [ ] Live smoke test
- [ ] Profile threaded from user-selected profile (currently hard-coded `.deep`) — deferred to profile-selection UX follow-up
- [ ] Glob walking for `**/` patterns — blocked by gargantua-avik

### Remaining
- Live smoke test (user runs the app and confirms scan → confirm → clean works on a real path)
- Threading selected profile from Settings (follow-up; currently uses `.deep` which is the right default for this view anyway)
