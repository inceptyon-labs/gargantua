---
# gargantua-r8vu
title: 'Feature: Folder-grouped Deep Clean results with size sort and drill-down'
status: completed
type: feature
priority: normal
created_at: 2026-04-17T12:16:16Z
updated_at: 2026-04-21T19:12:05Z
---

## Problem

Deep Clean results are a flat list grouped only by safety bucket (safe/review/protected). For a large scan (hundreds of items across dozens of folders), it's a massive list with no hierarchy and no explicit size sort. `ScanBucketListView` just does `ForEach(bucket.items)` per bucket.

User report (2026-04-17): "deep scan results can be organized better, it is just a massive list, maybe by folder that you can drill into, also sorted by size".

## Scope

Add an alternate grouping mode: group by common parent folder, sort groups by total reclaimable bytes desc, drill-down expands to show items. Keep current safety grouping as the default so nothing regresses.

## Tasks

- [x] Add `ScanGroupingMode` enum: `safety` (default), `folder`, `category`
- [x] Add grouping toggle to `ScanBucketListView` header (segmented control or menu)
- [x] Implement folder grouping: one level by parent dir, no roll-up (deferred)
- [x] Implement category grouping: group by `result.category`
- [x] Sort groups by total size desc in both modes
- [x] Per-group header shows: folder name (or category), item count, total size
- [x] Expand/collapse per group with disclosure chevron (new `ScanGroupHeader`)
- [x] Keyboard nav (up/down, tab between groups) works in new modes
- [x] Selection state survives mode toggles (selectedIDs keyed by item id)
- [x] Smoke test: toggle modes on a real scan result, confirm drill-down works and sort is by size

## Non-goals

- Persisting last-used mode across launches (nice-to-have, not required)
- Multi-level folder tree (just one level of grouping for now)
- Changing the safety-bucket view

## Files

- `Sources/GargantuaCore/Views/ScanBucketView.swift` — main changes
- Tests for grouping logic: `Tests/GargantuaCoreTests/Views/ScanBucketViewTests.swift` (new or existing)

## Completion (2026-04-21)

Closed after verifying the code and smoke gates were already complete:

- `ScanGroupingMode` supports safety, folder, and category modes.
- `ScanBucketListView` exposes the grouping picker, expands groups after mode changes, preserves item-id keyed selection, and keeps keyboard navigation wired through the visible expanded rows.
- `ScanGrouper` groups folder/category results by parent path/category and sorts groups by total size descending; items within groups sort by size descending.
- `ScanGroupHeader` provides disclosure and group selection state.
- Child task `gargantua-qwz4` completed the real Deep Clean smoke for safety/folder/category toggles, expand/collapse, size ordering, selection persistence, and keyboard usability.

Verification:
- `swift test` passed on 2026-04-21: 848 tests across 107 suites.
- No source changes were needed for this closeout; this bean was stale after the child smoke task completed.
