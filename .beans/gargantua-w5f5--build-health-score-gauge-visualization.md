---
# gargantua-w5f5
title: Build health score gauge visualization
status: todo
type: task
priority: high
tags:
    - area:frontend
    - pasiv
    - size:M
created_at: 2026-04-15T00:48:26Z
updated_at: 2026-04-15T00:48:26Z
parent: gargantua-ggkx
---

0-100 gauge as the dashboard anchor. Score displayed as Display type (28px, 700 weight). Gauge tints by range: green (80-100), amber (50-79), red (<50).

## Acceptance Criteria
- [ ] Gauge renders as circular arc (consistent with confidence orbit aesthetic)
- [ ] Score number prominent in center (28px, 700 weight)
- [ ] "Health" caption below in --ink-2, 11px
- [ ] Color transitions: --safe for healthy, --review for moderate, --protected for poor
- [ ] Animates on value change (300ms, linear)

---
**Size:** M
