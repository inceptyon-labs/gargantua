---
# gargantua-gszj
title: Implement keyboard interaction for scan results
status: in-progress
type: task
priority: normal
tags:
    - area:frontend
    - pasiv
    - size:M
created_at: 2026-04-15T00:48:46Z
updated_at: 2026-04-16T01:14:50Z
parent: gargantua-rbpd
---

Arrow keys navigate, Space toggles selection, Cmd+A selects all safe items, Enter triggers clean, Escape cancels.

## Acceptance Criteria
- [ ] Up/Down arrows navigate between items with visible focus ring (--border-focus)
- [ ] Space toggles selection of focused item
- [ ] Cmd+A selects all safe items (ignores review and protected)
- [ ] Enter triggers clean flow for selected items
- [ ] Tab moves between buckets

---
**Size:** M
