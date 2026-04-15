---
# gargantua-xyka
title: Implement YAML rule parser in Swift
status: todo
type: task
priority: critical
tags:
    - area:backend
    - pasiv
    - size:L
created_at: 2026-04-15T00:47:32Z
updated_at: 2026-04-15T00:47:32Z
parent: gargantua-5la2
---

Swift parser that reads YAML rule files and produces typed ScanRule objects. Uses Yams or similar YAML library.

## Acceptance Criteria
- [ ] Parses all rule schema fields correctly
- [ ] Handles missing optional fields with sensible defaults
- [ ] Reports parse errors with file path and line number
- [ ] Loads rules from cleanup_rules/ directory structure
- [ ] Unit tests cover happy path and malformed YAML

---
**Size:** L
