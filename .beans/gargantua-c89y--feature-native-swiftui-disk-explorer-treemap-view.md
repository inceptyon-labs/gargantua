---
# gargantua-c89y
title: 'Feature: Native SwiftUI Disk Explorer treemap view'
status: todo
type: feature
priority: normal
tags:
    - area:frontend
    - size:M
created_at: 2026-04-23T23:00:20Z
updated_at: 2026-04-23T23:00:20Z
---

PRD §5.5 calls for a native SwiftUI treemap view for Disk Explorer. The shipped Disk Explorer is functional, but it is a sorted expandable list with size bars rather than a weighted-rectangle treemap.

## Evidence

- `Sources/GargantuaCore/Views/DiskExplorerView.swift:3` describes the view as a "sorted expandable list of disk consumers with size bars."
- `Sources/GargantuaCore/Views/DiskExplorerView.swift:98` renders a `ScrollView` + `LazyVStack` of `DirectoryRowView` rows.
- `Sources/GargantuaCore/Views/DiskExplorerView.swift:321` renders per-row horizontal size bars, not a treemap layout.
- `docs/design-brief-app-shell.md:132` explicitly notes the PRD says "SwiftUI treemap view" while the Phase 1 implementation may use a sorted expandable list.
- Existing completed `gargantua-9xm6` scoped Disk Explorer to sorted list/size bars and marked treemap visualization out of scope.

## Scope

- Add a SwiftUI treemap visualization using weighted rectangles sized by `DirectoryItem.size`.
- Preserve existing drill-down, breadcrumb, permission-denied handling, partial-size indication, and streaming/progressive loading behavior.
- Decide whether treemap replaces the list or ships as a list/treemap toggle.
- Add layout/unit tests for rectangle allocation edge cases where practical.

## Acceptance Criteria

- [ ] Disk Explorer can render children as weighted rectangles proportional to size.
- [ ] Users can drill down from treemap cells and navigate back via breadcrumbs.
- [ ] Permission-denied and partial-size items have visible affordances.
- [ ] Existing sorted list behavior is preserved or intentionally replaced with tests/docs.
