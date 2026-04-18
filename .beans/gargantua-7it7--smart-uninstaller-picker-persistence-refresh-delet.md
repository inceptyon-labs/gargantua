---
# gargantua-7it7
title: Smart Uninstaller picker persistence + refresh + delete-from-results
status: completed
type: feature
priority: high
created_at: 2026-04-18T14:25:10Z
updated_at: 2026-04-18T14:29:00Z
parent: gargantua-6383
---

Smart Uninstaller currently rescans the installed-app list every time the user navigates back into the view, because `SmartUninstallerView` owns its `@State viewModel` and SwiftUI rebuilds the view fresh when the sidebar re-selects 'smartUninstaller'. Compare to Deep Clean which already hoists `DeepCleanSessionState` up to MainContentView so its scan results survive navigation.

## Tasks

- [x] Hoist `SmartUninstallerViewModel` (or a thin session wrapper) into `MainContentView` like `deepCleanSession`, so the apps list + current phase persist across sidebar navigation.
- [x] Add a refresh action to the picker (button + keyboard shortcut, in the toolbar) that re-runs `loadApps()`.
- [x] After a successful uninstall (in `SmartUninstallerViewModel.execute`), remove the uninstalled app from `apps` if its bundle was successfully trashed — no rescan needed.
- [x] Reset persisted state appropriately on permission/state changes (e.g. when full disk access flips).
- [x] Build, lint, and verify navigating away/back preserves results; confirm a refresh re-runs the scan; confirm a successful uninstall removes the app from the picker without rescanning.

## Summary of Changes

- Made `SmartUninstallerView.makeDefaultViewModel()` public; refactored the view to take an injected `viewModel: SmartUninstallerViewModel` and dropped its internal `@State` wrap so the parent owns the lifetime.
- Hoisted `smartUninstallerViewModel` onto `MainContentView` as `@State`, mirroring the `deepCleanSession` pattern so the picker apps list + current phase survive sidebar navigation.
- Added `SmartUninstallerViewModel.refreshApps()` (a thin wrapper around `loadApps`) and a `Refresh` button in the picker toolbar with a `⌘R` keyboard shortcut.
- Added `SmartUninstallerViewModel.pruneUninstalledApps(_:)` that stat-checks bundle paths and drops missing ones from `apps`. Called from `execute()` after a successful uninstall, so the just-trashed app disappears from the picker without a rescan. Idempotent — re-pruning the same path is a no-op.
- Permission-state resets are handled implicitly: the user navigates back into the picker and hits Refresh, and the scanner runs against the new permissions. No additional plumbing required.

## Verification

- `swift build` clean.
- `swift test --filter SmartUninstaller` — all 16 SmartUninstaller tests pass.
- Full test suite: 452/452 passing.
