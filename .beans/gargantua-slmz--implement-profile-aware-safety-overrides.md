---
# gargantua-slmz
title: Implement profile-aware safety overrides
status: in-progress
type: task
priority: high
tags:
    - area:backend
    - pasiv
    - size:M
created_at: 2026-04-15T00:47:49Z
updated_at: 2026-04-15T12:35:43Z
parent: gargantua-r7t3
---

Apply safety_overrides from YAML rules based on active cleanup profile and file metadata (age, size, last accessed).

## Acceptance Criteria
- [x] Developer profile: node_modules >30d auto-classified as safe
- [x] Deep profile: additional overrides for >7d items
- [x] Override includes modified confidence and explanation_suffix
- [x] Base safety level preserved when no override matches

---
**Size:** M
