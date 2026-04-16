---
# gargantua-215m
title: Implement mo analyze and mo status adapters
status: in-progress
type: task
priority: normal
tags:
    - area:backend
    - pasiv
    - size:M
created_at: 2026-04-15T00:48:07Z
updated_at: 2026-04-16T01:00:54Z
parent: gargantua-jj6r
---

mo analyze for Disk Explorer, mo status --json for system metrics (health score inputs).

## Acceptance Criteria
- [ ] mo analyze output mapped to disk usage tree structure
- [ ] mo status --json provides CPU, memory, disk, temperature metrics
- [ ] Both adapters handle timeout and partial output gracefully

---
**Size:** M
