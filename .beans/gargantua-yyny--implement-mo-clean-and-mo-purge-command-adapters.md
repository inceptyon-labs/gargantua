---
# gargantua-yyny
title: Implement mo clean and mo purge command adapters
status: todo
type: task
priority: high
tags:
    - area:backend
    - pasiv
    - size:M
created_at: 2026-04-15T00:48:07Z
updated_at: 2026-04-15T00:48:07Z
parent: gargantua-jj6r
---

Typed adapters for mo clean (Deep Clean) and mo purge (Dev Artifact Purge). Report progress through ScanProgress observable.

## Acceptance Criteria
- [ ] mo clean adapter produces ScanResult array with Trust Layer metadata
- [ ] mo purge adapter produces ScanResult array scoped to dev artifacts
- [ ] Progress updates emitted through ScanProgress observable
- [ ] Dry-run mode supported (scan without clean)

---
**Size:** M
