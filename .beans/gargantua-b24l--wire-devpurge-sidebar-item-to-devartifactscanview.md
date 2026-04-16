---
# gargantua-b24l
title: Wire devPurge sidebar item to DevArtifactScanView
status: completed
type: task
priority: high
tags:
    - area:frontend
    - pasiv
    - size:XS
created_at: 2026-04-16T11:06:29Z
updated_at: 2026-04-16T12:43:33Z
parent: gargantua-0zll
---

DevArtifactScanView is fully built but not reachable from the sidebar. Add a case in MainContentView's switch for 'devPurge' that instantiates MoleRunner + MoPurgeAdapter and passes them to DevArtifactScanView.

## Acceptance Criteria
- [ ] case 'devPurge' added to MainContentView switch
- [ ] MoleRunner and MoPurgeAdapter instantiated and passed to DevArtifactScanView
- [ ] Clicking Dev Artifact Purge in sidebar shows the scan view (no more Coming Soon)

## Summary of Changes

Files changed:
- Sources/Gargantua/MainContentView.swift (modified)

Key decisions:
- MoleRunner instantiated with defaults (resolves binary from bundle)
- MoPurgeAdapter passed directly to DevArtifactScanView

Notes for next task:
- DevArtifactScanView onClean callback is a TODO placeholder
