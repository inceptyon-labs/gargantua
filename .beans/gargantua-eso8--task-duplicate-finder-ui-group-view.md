---
# gargantua-eso8
title: 'Task: Duplicate Finder UI (group view)'
status: completed
type: task
priority: high
created_at: 2026-04-18T22:18:18Z
updated_at: 2026-04-19T02:28:57Z
parent: gargantua-4nb9
---

Build the Duplicate Finder UI surface: duplicate-group list, per-group file rows with short hash + size, review-by-default selection model, reclaimable bytes per group and total, action to send selected to trash. Must not execute destructive ops until Trust Layer confirmation flow is in place. Reference: Sources/GargantuaCore/Views/, FclonesAdapter.swift ScanResult output.



## Summary of Changes

Built the Duplicate Finder UI surface (group-view). Phase 2 fclones duplicate results can now be reviewed and selected — trash execution is deliberately gated behind the Trust Layer and left as a wiring task for the follow-up pipeline work.

**New files**
- `Sources/GargantuaCore/Views/DuplicateFinderModels.swift` — `DuplicateGroup` + `DuplicateGrouper` + `DuplicateFinderSelection`. Pure, testable. Overflow-safe bytes math mirrors `FclonesAdapter`'s reclaimable accounting (N−1) × fileLen.
- `Sources/GargantuaCore/Views/DuplicateFinderView.swift` — `DuplicateFinderView` with summary bar, group list, per-row dense row, action bar. Initial expansion limited to top-5 groups for scan-pile parseability. Selection binding is public, onSendToTrash is optional (disabled UI when nil).
- `Sources/GargantuaCore/Views/DuplicateGroupHeader.swift` — collapsible per-group header with tri-state checkbox + "Keep one" quick action.
- `Tests/GargantuaCoreTests/Views/DuplicateFinderModelTests.swift` — 22 tests covering grouping, hash extraction, sort stability, reclaimable math, Int64.max overflow clamp, selection state, and `selectAllButFirst` protected-file filtering.

**Modified**
- `Sources/Gargantua/MainContentView.swift` — wired `"duplicateFinder"` case with empty `results: []` and no-op `onSendToTrash` (intentionally unwired; Trust Layer flow is a later Task).
- `Sources/GargantuaCore/Views/SidebarView.swift` — new `duplicateFinder` sidebar item under CLEAN.
- `Tests/GargantuaCoreTests/Views/SidebarTests.swift` — updated default-IDs assertion.

**Baseline**: 634 → 656 tests (+22). `swift build -Xswiftc -warnings-as-errors` clean. `swiftlint --strict` clean on all touched files.

**SC review**: Sonnet Pass 1 found 0 ERRORs. Codex Pass 2 caught 2 ERRORs, both fixed in-branch:
- Protected duplicates rendered as toggleable `DenseScanItemRow` (no read-only path) — added `protectedRow` branch and defense-in-depth `selectableByID` map that sanitises `onSendToTrash` handoff and rejects unknown/protected ids in `toggleSelection`.
- `DuplicateFinderSelection.selectAllButFirst` could include protected files — filter by `safety != .protected_` before mapping.

Codex WARNINGs deferred (require live results pipeline or scan-identity context not yet wired):
- `groups` computed property recomputed on every body render (memoization deferred until scan wiring lands).
- `expandedGroupIDs` seeded only in init; stale if `results` swap.
- App-level `duplicateFinderSelection` has no scan identity; fclones ids are stable only within one scan, so cross-scan collisions are possible.

## Key Decisions (for follow-up Tasks)

- **`fclones_group_<id>` / `fclones_hash_<short>` tags are the grouping contract.** `DuplicateGrouper.group` only accepts rows that carry `fclones_group_`; everything else is dropped. The UI is deliberately fclones-specific rather than a generic "find duplicates in any ScanResult" view.
- **Reclaimable semantics differ between ceiling and selection.** `reclaimableCeilingBytes = (fileCount - 1) × perFileSize` (the maximum assuming "keep one"). `reclaimableBytes(selectedIDs:) = sum(size of selected files)` — matches user intent ("I picked these to trash; show me those bytes"). Both are overflow-clamped at `Int64.max`.
- **Selection is review-by-default (nothing pre-selected).** A per-group "Keep one" action sets `selectedIDs = files.dropFirst().filter(!protected)`. "First" is defined by path-ascending sort inside `DuplicateGrouper` so the keep-pick is deterministic across runs.
- **`onSendToTrash` is the Trust Layer boundary.** View never executes trash. Passing `nil` disables the Send-to-Trash button with a tooltip noting the Trust Layer gate. `selectedResults` is sanitised through the `selectableByID` map so stale or externally-mutated `selectedIDs` entries can never escape to a destructive callback.
- **Protected duplicates render read-only.** Even though `FclonesTrustDefaults` always emits `.review`, the view honours `.protected_` defensively in case future trust overrides flip a row — mirrors `ScanBucketView.protectedRow`.
- **Wiring to `ScanEngine` is a separate Task.** `MainContentView` passes `results: []` for now. Sibling Task `gargantua-rp82` (now unblocked) will introduce the multi-adapter scan pipeline that feeds this view.

Completed in 6d49b6c
