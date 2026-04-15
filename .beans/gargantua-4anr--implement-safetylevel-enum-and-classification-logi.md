---
# gargantua-4anr
title: Implement SafetyLevel enum and classification logic
status: todo
type: task
priority: critical
tags:
    - area:backend
    - pasiv
    - size:M
created_at: 2026-04-15T00:47:49Z
updated_at: 2026-04-15T00:47:49Z
parent: gargantua-r7t3
---

SafetyLevel enum (safe, review, protected) with associated behaviors: default selection state, UI color mapping, confirmation tier routing.

## Acceptance Criteria
- [ ] SafetyLevel.safe → auto-selected, --safe color, single-button confirm
- [ ] SafetyLevel.review → not selected, --review color, summary dialog
- [ ] SafetyLevel.protected → not actionable without override, --protected color, full modal
- [ ] Classification derived from YAML rules only — never from AI

---
**Size:** M
