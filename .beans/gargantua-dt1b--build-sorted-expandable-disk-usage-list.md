---
# gargantua-dt1b
title: Build sorted expandable disk usage list
status: in-progress
type: task
priority: normal
tags:
    - area:frontend
    - pasiv
    - size:L
created_at: 2026-04-15T00:49:09Z
updated_at: 2026-04-15T23:21:07Z
parent: gargantua-9xm6
---

Sorted list of disk consumers with size bars. Expand to drill into subdirectories. Progressive loading.

## Acceptance Criteria
- [x] Top-level shows largest directories sorted by size
- [x] Size bars: proportional width relative to largest item, --accent fill
- [x] Sizes in --font-mono with tabular numbers
- [x] Click to expand shows child directories (loaded on demand)
- [x] Permission-denied paths: grayed row with "Requires Full Disk Access" in --ink-4
- [x] Drill-down maintains breadcrumb trail

---
**Size:** L
