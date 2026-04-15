---
# gargantua-wehg
title: 'Epic: Data Layer & Models'
status: todo
type: epic
priority: high
tags:
    - area:backend
    - pasiv
created_at: 2026-04-15T00:44:55Z
updated_at: 2026-04-15T00:44:55Z
---

SwiftData models, persistence, and the core data types that all features depend on. ScanResult, CleanupProfile, AuditEntry, Settings — the data backbone.

## Vision
Clean, typed Swift models that carry Trust Layer metadata end-to-end. SwiftData for persistence. All scan engines produce the same ScanResult type.

## Features
- Core data models (ScanResult, SafetyLevel, CleanupProfile, AuditEntry)
- SwiftData persistence for scan history, profiles, settings
- Unified ScanProgress observable for all engines
- AIServiceProtocol definition

## Success Criteria
- [ ] ScanResult carries all Trust Layer fields (safety, confidence, explanation, source)
- [ ] Profiles persist across app launches
- [ ] Audit entries queryable by date range
- [ ] ScanProgress observable drives UI updates from any engine
