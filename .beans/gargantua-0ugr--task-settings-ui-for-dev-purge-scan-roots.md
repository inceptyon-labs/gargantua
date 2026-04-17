---
# gargantua-0ugr
title: 'Task: Settings UI for Dev Purge scan roots'
status: completed
type: task
priority: normal
created_at: 2026-04-17T01:59:59Z
updated_at: 2026-04-17T17:52:35Z
parent: gargantua-l9dk
---

`PersistedSettings.scanRoots: [String]` was added as part of gargantua-guga so project roots (parity with `mo purge --paths`) can persist across launches. No UI exists to edit them yet — user must set them via direct SwiftData writes.

Add a simple editor (probably in the Settings view or ProfileContainerView) for adding/removing/reordering stored scan roots. Defaults continue to come from `PathExpander.defaultScanRoots()` when the stored list is empty; MainContentView.resolvedScanRoots validates entries (empty, '/', '~' dropped).


## Summary of Changes

Added a Dev Purge scan-root editor to Settings. The editor supports typed path entry, macOS directory picking, removing roots, moving roots up/down, and resetting to auto-detected defaults when the stored list is empty.

Centralized scan-root validation in `ScanRootSettings` so Settings and `MainContentView.resolvedScanRoots` share the same behavior: trim entries, require absolute or `~/` paths, reject relative paths, `/`, and the home directory, and de-duplicate roots after tilde expansion/standardization.

**Files changed:**
- Sources/GargantuaCore/Views/SettingsView.swift
- Sources/GargantuaCore/Views/ScanRootsSettingsSection.swift
- Sources/GargantuaCore/Views/ScanRootsSettingsSupport.swift
- Sources/GargantuaCore/Persistence/ScanRootSettings.swift
- Sources/Gargantua/MainContentView.swift
- Tests/GargantuaCoreTests/Persistence/ScanRootSettingsTests.swift

**Verification:**
- `swift test` passed: 245 tests across 33 suites
- `swift build` passed
- `swiftlint lint` passed with 29 non-serious pre-existing warnings

**Review:**
- Manual diff review completed after verification; no blocking issues found.

## Merged

Completed locally by Codex on 2026-04-17.
