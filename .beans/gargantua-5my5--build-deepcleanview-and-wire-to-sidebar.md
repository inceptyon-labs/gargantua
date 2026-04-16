---
# gargantua-5my5
title: Build DeepCleanView and wire to sidebar
status: completed
type: task
priority: high
tags:
    - area:frontend
    - pasiv
    - size:M
created_at: 2026-04-16T11:06:36Z
updated_at: 2026-04-16T12:43:40Z
parent: gargantua-0zll
blocked_by:
    - gargantua-b24l
---

Create DeepCleanView using MoCleanAdapter + ScanBucketListView. Similar pattern to DevArtifactScanView but for system cleanup (browser cache, system logs, temp files, etc.). Wire to 'deepClean' sidebar item in MainContentView.

## Acceptance Criteria
- [ ] DeepCleanView created with scan trigger button
- [ ] Uses MoCleanAdapter to run scan, displays results in ScanBucketListView
- [ ] ScanProgress shown during scan
- [ ] case 'deepClean' added to MainContentView switch
- [ ] Clicking Deep Clean in sidebar shows the scan view

## Summary of Changes

Files changed:
- Sources/GargantuaCore/Views/DeepCleanView.swift (new)
- Sources/Gargantua/MainContentView.swift (modified)

Key decisions:
- Followed DevArtifactScanView pattern but simpler (no category selection)
- Start view with description + scan button, results in ScanBucketListView
- Separate isScanning state flag for view updates (scanProgress is actor-isolated)

Notes for next task:
- onClean callback is a TODO placeholder — needs ConfirmationModalView integration
- Error display shows first error from ScanProgress in footer
