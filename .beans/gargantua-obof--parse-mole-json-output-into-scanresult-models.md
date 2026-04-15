---
# gargantua-obof
title: Parse Mole JSON output into ScanResult models
status: todo
type: task
priority: high
tags:
    - area:backend
    - pasiv
    - size:M
created_at: 2026-04-15T00:48:07Z
updated_at: 2026-04-15T00:48:07Z
parent: gargantua-rsnu
---

Parse JSON output from mo commands into typed ScanResult array. Map Mole categories to Trust Layer safety levels.

## Acceptance Criteria
- [ ] JSON parsing handles all Mole output fields
- [ ] Category-to-safety mapping covers all Mole categories
- [ ] Missing/unexpected fields handled gracefully (log, skip, continue)
- [ ] Unit tests with sample Mole JSON output

---
**Size:** M
