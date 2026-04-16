---
# gargantua-1m6x
title: Wire confirmation modal into scan views
status: todo
type: task
priority: normal
tags:
    - area:frontend
    - pasiv
    - size:S
created_at: 2026-04-16T11:06:51Z
updated_at: 2026-04-16T11:06:51Z
parent: gargantua-omp3
blocked_by:
    - gargantua-0zll
---

When user clicks Clean in ScanBucketListView (onClean callback), show ConfirmationModalView with appropriate tier based on item count and safety levels. Currently onClean is a no-op closure.

## Acceptance Criteria
- [ ] onClean in DeepCleanView and DevArtifactScanView triggers ConfirmationModalView
- [ ] Tier selection: 1 safe item → Tier 1, multiple items → Tier 2, any review items → Tier 3
- [ ] Confirmation proceeds to CleanupEngine execution
- [ ] Cancel dismisses modal without action
