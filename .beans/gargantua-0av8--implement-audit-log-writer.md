---
# gargantua-0av8
title: Implement audit log writer
status: todo
type: task
priority: high
tags:
    - area:backend
    - pasiv
    - size:M
created_at: 2026-04-15T00:47:49Z
updated_at: 2026-04-15T00:47:49Z
parent: gargantua-dshb
---

JSON audit log at ~/Library/Logs/Gargantua/audit.json. Every destructive operation logged.

## Acceptance Criteria
- [ ] Entry includes: timestamp, tool/engine, command, files (paths + sizes), safety level, confirmation method
- [ ] Appends to existing log file (JSONL format)
- [ ] Creates directory structure if missing
- [ ] Thread-safe writes

---
**Size:** M
