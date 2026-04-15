---
# gargantua-lv3r
title: Build dense scan item row component
status: todo
type: task
priority: high
tags:
    - area:frontend
    - pasiv
    - size:L
created_at: 2026-04-15T00:48:46Z
updated_at: 2026-04-15T00:48:46Z
parent: gargantua-rbpd
---

Item row: confidence orbit | checkbox | name + explanation | file path | size. All data visible (dense mode). Safety classification via background tint, not badge pills.

## Acceptance Criteria
- [ ] Confidence orbit (24x24) colored by safety level
- [ ] Name: 13px, 500 weight, --ink
- [ ] Explanation: 13px, 400 weight, --ink-2, same line or below name
- [ ] File path: --font-mono, 11px, --ink-3, truncated with ellipsis
- [ ] Size: --font-mono, 12px, --ink, tabular numbers, right-aligned
- [ ] Row background: safety-dim tint color
- [ ] Hover: reveal "?" explain button
- [ ] Select/deselect on click

---
**Size:** L
