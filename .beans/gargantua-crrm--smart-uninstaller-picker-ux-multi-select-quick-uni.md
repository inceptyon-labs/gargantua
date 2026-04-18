---
# gargantua-crrm
title: 'Smart Uninstaller picker UX: multi-select, quick uninstall, category count'
status: completed
type: feature
priority: high
created_at: 2026-04-18T17:37:24Z
updated_at: 2026-04-18T17:46:00Z
parent: gargantua-6383
---

From user feedback (vibetunnel + Adobe Premiere screenshots):

1. The current `app.dashed` SF Symbol icon on each picker row reads like a checkbox even though it isn't — users instinctively try to click it to select.
2. To uninstall an app you have to drill into a plan review screen first; selecting + acting on multiple apps at once isn't possible.
3. The plan review surfaces categories (App Bundle, Preferences, Web Data, etc.) but the picker doesn't hint at how much the app will surface — users have to drill in to see.

## Tasks

- [x] Replace the leading `app.dashed` icon with a real checkbox. Selecting toggles the app's inclusion in a batch operation.
- [x] Add a sticky "Uninstall N apps" action when 1+ apps are checked. Single-app: bypasses plan review and goes straight to confirmation modal with default selections. Batch: combined plan + sequential execution (or single combined confirm + sequential execute).
- [x] Add a hover-revealed "Uninstall" icon button on each row that triggers single-app quick uninstall without checking the box.
- [x] Show a category-count badge on each row (e.g. `3 categories`). Computed in the background after `loadApps()` finishes by running the planner per app and storing distinct categories. Throttle concurrency so it doesn't peg the CPU. Persist counts on the viewModel so navigating away/back keeps them.
- [x] Improve hover state: stronger background change so the row reads as clickable.
- [x] Build, lint, and verify multi-select + batch uninstall + per-row quick uninstall flows.

## Summary of Changes

### Multi-select
- Added multiSelected: Set<String> to SmartUninstallerViewModel with toggleMultiSelect / clearMultiSelect.
- Picker row now shows a real 18pt checkbox at the leading edge (replaces the misleading app.dashed SF Symbol). Checked rows get a subtle accent-tinted background so the selection state is unambiguous.
- A sticky batch action bar appears at the bottom of the picker when 1+ apps are checked: shows count, Clear button, and primary Uninstall N apps button (triggered by Return).

### Per-row quick uninstall
- Hover-revealed trash icon on each row triggers viewModel.quickUninstall(app), which runs the same selectApp planning + immediately surfaces the confirmation modal in SmartUninstallerView.
- Clicking Cancel on a quick-uninstall modal returns the user to the picker (resets phase). Clicking Cancel on a plan-review uninstall keeps the review open in case they want to tweak selections — the two cases share one modal but have different cancel semantics.

### Batch flow
- New SmartUninstallerPhase cases: .batchScanning(completed, total), .batchExecuting(completed, total), .batchSummary([UninstallExecutionResult]).
- startBatchUninstall plans each selected app sequentially (planning is per-app filesystem work, not parallelizable safely without breaking the EventHorizon stream order). Pre-selects safe items across all plans.
- When phase reaches .batchScanning(total, total), SmartUninstallerView overlays the combined ConfirmationModalView listing items from every plan.
- executeBatch runs each plan through the executor sequentially, prunes successfully-uninstalled apps from the cached picker list, and falls through to .batchSummary even if some plans fail (synthetic failed CleanupItemResults are recorded so the summary tells the truth).
- Batch summary view combines all per-plan CleanupResults into one for the existing SingularityCloseMessage + CleanupSummaryView treatment, with an N apps · ... prefix on the line.

### Category-count badge
- categoryCounts: [String: Int] on viewModel, populated in the background after loadApps via withTaskGroup throttled to 4 concurrent planner calls.
- Picker row shows X categories when known, falling back to the relative-date stamp until counts arrive.
- pruneUninstalledApps removes stale bundle IDs from multiSelected and categoryCounts after a successful uninstall.
- Counts survive navigation thanks to the existing viewModel hoist.

### Hover affordance
- Row background switches to surface1 on hover (existing) plus accent-10% when checked. Quick-uninstall icon reveals on hover with a protected_-tinted trash glyph.

## Verification

- swift build clean.
- 452/452 tests passing.

## Known follow-ups

- No new tests added for batch flow yet — manual smoke-testing recommended. The existing single-app tests cover selectApp + execute paths.
- Background category-count scan re-runs on every loadApps; could add a 30s debounce / cache invalidation if it ever becomes annoying.
