---
# gargantua-k2og
title: Define YAML scan rule schema
status: completed
type: task
priority: critical
tags:
    - area:backend
    - pasiv
    - size:M
created_at: 2026-04-15T00:47:32Z
updated_at: 2026-04-15T01:15:07Z
parent: gargantua-5la2
---

Define the declarative rule format: id, name, paths, pattern, exclude, safety, confidence, explanation, source (name, bundle_id, verify_signature), regenerates, regenerate_command, category, tags, safety_overrides.

## Acceptance Criteria
- [x] Schema documented with all fields and types
- [x] Safety overrides support condition expressions (age > Nd)
- [x] Profile-aware overrides specify which profiles they apply to
- [x] Schema supports source verification (bundle_id, signature)

---
**Size:** M



---
Completed in commit 5e71f45
