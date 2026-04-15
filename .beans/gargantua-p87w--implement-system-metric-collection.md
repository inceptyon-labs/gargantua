---
# gargantua-p87w
title: Implement system metric collection
status: todo
type: task
priority: high
tags:
    - area:backend
    - pasiv
    - size:M
created_at: 2026-04-15T00:48:26Z
updated_at: 2026-04-15T00:48:26Z
parent: gargantua-ggkx
---

Collect CPU usage, memory pressure, disk usage, and thermal state. Derive health score. Phase 1: mo status fallback, native sysctl/IOKit preferred.

## Acceptance Criteria
- [ ] CPU: usage percentage via host_processor_info or mo status
- [ ] Memory: used/total via host_statistics or mo status
- [ ] Disk: used/total/free via FileManager or mo status
- [ ] Temperature: thermal state via NSProcessInfo.thermalState
- [ ] Health score algorithm weights all four inputs

---
**Size:** M
