---
# gargantua-6gyb
title: Implement cleanup execution and post-clean summary
status: todo
type: task
priority: high
tags:
    - area:backend
    - area:frontend
    - pasiv
    - size:M
created_at: 2026-04-15T00:49:09Z
updated_at: 2026-04-15T00:49:09Z
parent: gargantua-yzi8
---

Execute cleanup (move to Trash), write audit entry, show summary with freed space and undo option.

## Acceptance Criteria
- [ ] Files moved to Trash via NSWorkspace or Finder automation
- [ ] Audit entry written with all metadata
- [ ] Post-clean summary: items cleaned, total freed, audit trail link
- [ ] Undo button reveals Trash
- [ ] Error handling: partial failure shows which items succeeded/failed

---
**Size:** M
