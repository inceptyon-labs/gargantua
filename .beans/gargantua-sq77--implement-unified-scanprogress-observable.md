---
# gargantua-sq77
title: Implement unified ScanProgress observable
status: todo
type: task
priority: high
tags:
    - area:backend
    - pasiv
    - size:S
created_at: 2026-04-15T00:49:48Z
updated_at: 2026-04-15T00:49:48Z
parent: gargantua-3t5d
---

Observable that all scan engines publish to. Drives UI progress indicators regardless of which engine is running.

## Acceptance Criteria
- [ ] @Observable class with: isScanning, progress (0-1), currentCategory, itemsFound, errors
- [ ] All engine adapters (Mole, future native) publish through this
- [ ] UI components observe for real-time updates
- [ ] Thread-safe for concurrent access

---
**Size:** S
