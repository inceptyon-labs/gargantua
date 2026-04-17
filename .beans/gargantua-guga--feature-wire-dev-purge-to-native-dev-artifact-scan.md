---
# gargantua-guga
title: 'Feature: Wire Dev Purge to native dev-artifact scanner'
status: completed
type: feature
priority: critical
created_at: 2026-04-17T01:06:45Z
updated_at: 2026-04-17T02:01:02Z
parent: gargantua-l9dk
---

Replace MoPurgeAdapter in the Dev Artifact Purge view with a native scanner path that walks configured project roots for glob rules like node_modules, .gradle, target, DerivedData, etc.

## Acceptance Criteria
- [x] `MainContentView.swift:57-60` — `DevArtifactScanView(adapter:)` no longer takes `MoPurgeAdapter`
- [x] Native dev-artifact scan honors the `dev_artifacts`, `docker`, `homebrew` categories (via new `CleanupProfile.devPurge`)
- [x] Glob rules like `**/node_modules` actually match — PathExpander from gargantua-avik
- [x] User-configurable scan roots persisted in `PersistedSettings.scanRoots`; defaults auto-detected via `PathExpander.defaultScanRoots()` (~/Projects, ~/GitHub, ~/dev, ~/www, etc.); Settings UI follow-up filed separately
- [x] Confirmation + `CleanupEngine` flow unchanged
- [x] `swift build` clean; live smoke test pending user run

## Wiring Checklist
- [x] Update `MainContentView.swift:57-60` to construct a native-backed adapter
- [x] Update `DevArtifactScanView.swift` init + scan trigger
- [x] Added `scanRoots: [String]` to `PersistedSettings` (SwiftData); Settings UI deferred to follow-up
- [x] Route scan through `NativeScanAdapter.loadDefaults(profile:scanRoots:)`
- [x] No more callers — deletion tracked in gargantua-2xrw

## Out of Scope
- Glob walker implementation itself (separate task)
- Homebrew / Docker sub-commands (Phase 2 feature per PRD §11)


## Summary of Changes
Replaced `MoPurgeAdapter(runner: MoleRunner())` in `DevArtifactScanView` with `NativeScanAdapter.loadDefaults(profile:scanRoots:)`, mirroring the lupo Deep Clean pattern. Added a new `CleanupProfile.devPurge` (scoped to `dev_artifacts`, `docker`, `homebrew` only — the `.developer` profile would have pulled in browser/system/temp rules). Added `PersistedSettings.scanRoots: [String]` so project roots can be persisted; defaults come from `PathExpander.defaultScanRoots()`, and stored entries are validated (empty/`/`/`~` dropped) before reaching the adapter. Walker-cap warnings now render in the results view instead of being silently dropped. Codex SC review caught four regressions (wrong profile scope, stale category rows with no backing rules, unsafe `defaultScanRoots` home fallback, missing scan-root validation) — all fixed before merge.

MoPurgeAdapter and its tests remain; gargantua-2xrw covers final removal.


## Merged
Completed in 719a812 (merged to main).
