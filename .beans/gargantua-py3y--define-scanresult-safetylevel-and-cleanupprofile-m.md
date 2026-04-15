---
# gargantua-py3y
title: Define ScanResult, SafetyLevel, and CleanupProfile models
status: todo
type: task
priority: critical
tags:
    - area:backend
    - pasiv
    - size:M
created_at: 2026-04-15T00:49:48Z
updated_at: 2026-04-15T00:49:48Z
parent: gargantua-3t5d
---

Core Swift types that all features depend on. Codable + SwiftData @Model.

## Acceptance Criteria
- [ ] ScanResult: id, name, path, size, safety (SafetyLevel), confidence, explanation, source, lastAccessed, category, tags
- [ ] SafetyLevel: enum with safe/review/protected, color mapping, selection behavior
- [ ] CleanupProfile: name, categories, isActive, safetyOverrides
- [ ] AuditEntry: timestamp, tool, command, files, safetyLevel, confirmationMethod
- [ ] All types Codable for JSON serialization
- [ ] @Model annotations for SwiftData persistence

---
**Size:** M
