---
# gargantua-mqc6
title: Wire CleanupEngine execution and post-cleanup summary
status: todo
type: task
priority: normal
tags:
    - area:frontend
    - area:backend
    - pasiv
    - size:M
created_at: 2026-04-16T11:06:58Z
updated_at: 2026-04-16T11:06:58Z
parent: gargantua-omp3
blocked_by:
    - gargantua-1m6x
---

After confirmation modal approves, execute CleanupEngine.clean() on selected items. Show CleanupSummaryView with results. Wire TrashRevealer for 'Reveal in Trash' button. Record operations via AuditWriter.

## Acceptance Criteria
- [ ] CleanupEngine.clean() called with confirmed items
- [ ] Progress indicator during cleanup execution
- [ ] CleanupSummaryView shown after cleanup completes (freed space, item count, failures)
- [ ] 'Reveal in Trash' button uses TrashRevealer to open Finder
- [ ] AuditWriter records each cleanup operation with timestamp and engine source
- [ ] Failed items shown with error descriptions
