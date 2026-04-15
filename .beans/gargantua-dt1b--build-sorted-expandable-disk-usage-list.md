---
# gargantua-dt1b
title: Build sorted expandable disk usage list
status: todo
type: task
priority: normal
tags:
    - area:frontend
    - pasiv
    - size:L
created_at: 2026-04-15T00:49:09Z
updated_at: 2026-04-15T00:49:09Z
parent: gargantua-9xm6
---

Sorted list of disk consumers with size bars. Expand to drill into subdirectories. Progressive loading.

## Acceptance Criteria
- [ ] Top-level shows largest directories sorted by size
- [ ] Size bars: proportional width relative to largest item, --accent fill
- [ ] Sizes in --font-mono with tabular numbers
- [ ] Click to expand shows child directories (loaded on demand)
- [ ] Permission-denied paths: grayed row with "Requires Full Disk Access" in --ink-4
- [ ] Drill-down maintains breadcrumb trail

---
**Size:** L
