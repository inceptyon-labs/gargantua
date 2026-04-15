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
updated_at: 2026-04-15T12:32:59Z
parent: gargantua-r7t3
---

Apply safety_overrides from YAML rules based on active cleanup profile and file metadata (age, size, last accessed).

## Acceptance Criteria
- [ ] Developer profile: node_modules >30d auto-classified as safe
- [ ] Deep profile: additional overrides for >7d items
- [ ] Override includes modified confidence and explanation_suffix
- [ ] Base safety level preserved when no override matches

---
**Size:** M
