---
# gargantua-py3y
title: Define ScanResult, SafetyLevel, and CleanupProfile models
status: completed
type: task
priority: critical
tags:
    - area:backend
    - pasiv
    - size:M
created_at: 2026-04-15T00:49:48Z
updated_at: 2026-04-15T01:02:21Z
parent: gargantua-3t5d
---

## Completion Summary

Files created:
- Package.swift (Swift Package, macOS 14+)
- Sources/GargantuaCore/Models/SafetyLevel.swift
- Sources/GargantuaCore/Models/ScanResult.swift
- Sources/GargantuaCore/Models/CleanupProfile.swift
- Sources/GargantuaCore/Models/AuditEntry.swift
- Tests/GargantuaCoreTests/Models/SafetyLevelTests.swift
- Tests/GargantuaCoreTests/Models/ScanResultTests.swift
- Tests/GargantuaCoreTests/Models/CleanupProfileTests.swift

Key decisions:
- Models are thin transport/value types, not SwiftData @Model entities yet
- SafetyLevel uses protected_ with raw value "protected" (Swift keyword workaround)
- ScanResult.safety is var (mutable) for profile override support
- AuditEntry uses UUID for id, ScanResult uses String
- Three built-in profiles: Developer, Light, Deep — each with safety overrides
- Codex review noted path validation should happen in adapter layer, not models

Notes for next task:
- Import GargantuaCore to use these types
- SafetyLevel, ConfirmationTier, CleanupMethod are the key enums
- CleanupProfile.builtIn gives all three default profiles
- ScanResult is the universal type all scan engines must produce
- @Model annotations for SwiftData should wrap these, not replace them
