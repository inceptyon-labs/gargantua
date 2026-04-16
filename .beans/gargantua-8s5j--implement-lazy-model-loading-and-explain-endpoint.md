---
# gargantua-8s5j
title: Implement lazy model loading and explain endpoint
status: in-progress
type: task
priority: normal
tags:
    - area:backend
    - pasiv
    - size:L
created_at: 2026-04-15T00:49:31Z
updated_at: 2026-04-16T00:50:52Z
parent: gargantua-swvt
---

Load model on first "?" click. Unload after 60s idle. Generate file explanations. Fall back to YAML explanation string when no model available.

## Acceptance Criteria
- [ ] Model loaded into memory only on explicit AI feature use
- [ ] Auto-unload after 60s of inactivity
- [ ] RAM usage stays under 3 GB during model operation
- [ ] Explain button: generates explanation of file and its safety level
- [ ] Without model: "?" shows YAML rule explanation string instead
- [ ] AIServiceProtocol conformance for Tier 1

---
**Size:** L
