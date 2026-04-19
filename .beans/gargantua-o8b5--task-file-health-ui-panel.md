---
# gargantua-o8b5
title: 'Task: File Health UI panel'
status: completed
type: task
priority: high
created_at: 2026-04-18T22:18:25Z
updated_at: 2026-04-19T23:58:19Z
parent: gargantua-0q30
---

Build the File Health UI panel surfacing czkawka_cli categories: empty files/folders (safe), broken symlinks (safe), temporary files (safe), big files (review), similar images/videos (review), broken/corrupt files (review). Each category tab with Trust Layer visual defaults. Reference: Sources/GargantuaCore/Views/, CzkawkaOutputParser.swift CzkawkaCategory.


## Summary of Changes

### New files
- `Sources/GargantuaCore/Views/FileHealthModels.swift` — display metadata on `CzkawkaCategory` (label, SF Symbol), `FileHealthCategoryTab` wrapping a category with resolved safety/count/bytes, and `FileHealthGrouper` which flattens `[ScanResult]` into one tab per category present. Tabs are ordered safe-first / review-second, and tab safety escalates to the least-safe level across findings so a future `SafetyClassifier` downgrade can't be masked by the category default.
- `Sources/GargantuaCore/Views/FileHealthContainerView.swift` — scan-state owner (idle / scanning / results / error) mirroring `DuplicateFinderContainerView`. Wraps `CzkawkaAdapter` in a `ScanEngine` by default. Per-scan generation counter + fresh `ScanProgress` per attempt keep late completions / stale errors from corrupting new state. `.onDisappear` cancels the in-flight scan so czkawka subprocesses don't outlive the panel.
- `Sources/GargantuaCore/Views/FileHealthView.swift` — horizontal tab strip with Trust Layer coloring (safe = green token, review = amber token), per-tab scrollable findings list with reveal-in-Finder / copy-path / explain context menu. Partial-failure banner surfaces adapter-recorded warnings (e.g., single category's subcommand failed) so an incomplete audit isn't misread as a clean bill of health.
- `Tests/GargantuaCoreTests/Views/FileHealthGrouperTests.swift` — 8 tests: grouping, safe-first ordering, tab metadata, reverse-lookup, overflow-safe total size, mixed-safety escalation.
- `Tests/GargantuaCoreTests/Views/FileHealthContainerStateTests.swift` — 4 tests covering every `deriveScanState` transition (clean results, partial failure with warnings, all-failed → error, empty clean).

### Modified files
- `Sources/GargantuaCore/Views/SidebarView.swift` — adds "File Health" under CLEAN (stethoscope icon). Note: this shifts Cmd+5 from Disk Explorer to File Health.
- `Sources/Gargantua/MainContentView.swift` — routes `"fileHealth"` selection to `FileHealthContainerView`.

### Review
- SC pipeline: Sonnet + Codex.
- Sonnet caught a stale-tab-selection bug where `selectedTabID` pointing at a now-gone tab could leave every chip visually unselected (fixed).
- Codex caught four real issues, all addressed: (1) partial category failures now surface a warnings banner instead of silently succeeding, (2) scan task now cancels on view disappear, (3) fresh `ScanProgress` per attempt to avoid cross-scan mutation, (4) "total bytes" renamed to "flagged" because similarity groups expect a keep-one pattern.

### Deferred — not in this bean
- Destructive "Send to Trash" action. Requires the Trust Layer / `ConfirmationModalView` confirmation flow (same reason `DuplicateFinderContainerView` has `onSendToTrash = nil` today). Will land alongside `gargantua-i36a` (wire `CzkawkaAdapter` through `SafetyClassifier`) so File Health deletions route through the same policy the Duplicate Finder will.
- Per-item selection UI (checkboxes). Read-only today.

### Stats
- Full test suite: 681/681 passing (+12 new tests).
- Lint: clean on all new/changed files.
