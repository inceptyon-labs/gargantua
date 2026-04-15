---
# gargantua-hjrd
title: Implement Trash-based undo and retention policy
status: in-progress
type: task
priority: normal
tags:
    - area:backend
    - pasiv
    - size:M
created_at: 2026-04-15T00:47:49Z
updated_at: 2026-04-15T12:40:44Z
parent: gargantua-dshb
---

Undo button linking to Trash for recent operations. 90-day log retention, configurable.

## Acceptance Criteria
- [x] Cleaned files moved to Trash via NSWorkspace or Finder automation
- [x] Undo button in post-clean summary reveals items in Trash
- [x] Audit log entries older than retention period auto-purged on app launch
- [x] Retention period configurable in Settings (default 90 days)

---
**Size:** M
