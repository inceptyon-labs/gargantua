---
# gargantua-k2og
title: Define YAML scan rule schema
status: todo
type: task
priority: critical
tags:
    - area:backend
    - pasiv
    - size:M
created_at: 2026-04-15T00:47:32Z
updated_at: 2026-04-15T00:47:32Z
parent: gargantua-5la2
---

Define the declarative rule format: id, name, paths, pattern, exclude, safety, confidence, explanation, source (name, bundle_id, verify_signature), regenerates, regenerate_command, category, tags, safety_overrides.

## Acceptance Criteria
- [ ] Schema documented with all fields and types
- [ ] Safety overrides support condition expressions (age > Nd)
- [ ] Profile-aware overrides specify which profiles they apply to
- [ ] Schema supports source verification (bundle_id, signature)

---
**Size:** M
