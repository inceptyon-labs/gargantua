---
# gargantua-cgg5
title: Set up SwiftData container and persistence operations
status: todo
type: task
priority: high
tags:
    - area:backend
    - pasiv
    - size:M
created_at: 2026-04-15T00:49:48Z
updated_at: 2026-04-15T00:49:48Z
parent: gargantua-1ila
---

ModelContainer setup, model registration, CRUD for profiles/settings/audit. Retention cleanup for audit log.

## Acceptance Criteria
- [ ] ModelContainer configured with all @Model types
- [ ] Profiles persist across app launches
- [ ] Settings persist across app launches
- [ ] Audit entries queryable by date range
- [ ] Retention cleanup: entries older than configured period purged on launch
- [ ] Scan history: last scan date and top-level results per category

---
**Size:** M
