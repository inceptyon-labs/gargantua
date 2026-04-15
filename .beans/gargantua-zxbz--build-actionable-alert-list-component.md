---
# gargantua-zxbz
title: Build actionable alert list component
status: in-progress
type: task
priority: high
tags:
    - area:frontend
    - pasiv
    - size:M
created_at: 2026-04-15T00:48:26Z
updated_at: 2026-04-15T01:32:39Z
parent: gargantua-t1zs
---

Dense list of alerts showing reclaimable space by category. Each alert links to the relevant scan screen.

## Acceptance Criteria
- [ ] Alerts display: "23 GB of stale dev artifacts (>30 days)" format
- [ ] Each alert has click-through to relevant screen (Deep Clean, Dev Purge)
- [ ] Reclaimable sizes from last scan or live Quick Scan
- [ ] Uses --ink for primary text, --ink-2 for details, --font-mono for sizes
- [ ] Empty state: "No reclaimable items found" (factual, not emotional)

---
**Size:** M
