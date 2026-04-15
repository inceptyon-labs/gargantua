---
# gargantua-upkf
title: Build confirmation modal with itemized list
status: todo
type: task
priority: high
tags:
    - area:frontend
    - pasiv
    - size:M
created_at: 2026-04-15T00:49:09Z
updated_at: 2026-04-15T00:49:09Z
parent: gargantua-yzi8
---

Modal with --surface-3 background. Lists selected items with safety marks and sizes. Total at bottom. Confirmation tier routing based on item mix.

## Acceptance Criteria
- [ ] Modal: --surface-3, 8px radius, centered
- [ ] Itemized list scrollable if > 10 items
- [ ] Total: "Clean 45 items (18.2 GB) · Move to Trash"
- [ ] Destructive button: --protected background, white text
- [ ] Cancel button: ghost (--border-em border only), visually dominant escape
- [ ] All-safe: simplified single button (skip modal)
- [ ] Mixed safe+review: summary dialog listing review items explicitly
- [ ] Any protected selected: full modal with item-by-item acknowledgment

---
**Size:** M
