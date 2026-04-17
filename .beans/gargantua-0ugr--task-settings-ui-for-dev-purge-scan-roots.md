---
# gargantua-0ugr
title: 'Task: Settings UI for Dev Purge scan roots'
status: todo
type: task
priority: normal
created_at: 2026-04-17T01:59:59Z
updated_at: 2026-04-17T02:00:24Z
parent: gargantua-l9dk
---

`PersistedSettings.scanRoots: [String]` was added as part of gargantua-guga so project roots (parity with `mo purge --paths`) can persist across launches. No UI exists to edit them yet — user must set them via direct SwiftData writes.

Add a simple editor (probably in the Settings view or ProfileContainerView) for adding/removing/reordering stored scan roots. Defaults continue to come from `PathExpander.defaultScanRoots()` when the stored list is empty; MainContentView.resolvedScanRoots validates entries (empty, '/', '~' dropped).
