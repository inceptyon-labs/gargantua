---
# gargantua-r8vu
title: 'Feature: Folder-grouped Deep Clean results with size sort and drill-down'
status: in-progress
type: feature
priority: normal
created_at: 2026-04-17T12:16:16Z
updated_at: 2026-04-17T12:33:43Z
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
- [ ] Smoke test: toggle modes on a real scan result, confirm drill-down works and sort is by size

## Non-goals

- Persisting last-used mode across launches (nice-to-have, not required)
- Multi-level folder tree (just one level of grouping for now)
- Changing the safety-bucket view

## Files

- `Sources/GargantuaCore/Views/ScanBucketView.swift` — main changes
- Tests for grouping logic: `Tests/GargantuaCoreTests/Views/ScanBucketViewTests.swift` (new or existing)
