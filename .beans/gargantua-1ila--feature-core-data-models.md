---
# gargantua-1ila
title: 'Feature: Core Data Models'
status: in-progress
type: feature
priority: critical
tags:
    - area:backend
    - pasiv
created_at: 2026-04-15T00:46:41Z
updated_at: 2026-04-15T12:50:48Z
parent: gargantua-wehg
---

Swift types that carry Trust Layer metadata end-to-end. Every scan engine produces the same ScanResult.

## Goals
- ScanResult: id, name, path, size, safety, confidence, explanation, source, lastAccessed, category, tags
- SafetyLevel enum with associated colors and behaviors
- CleanupProfile: name, categories, safety overrides
- AuditEntry: timestamp, tool, command, files, safety, confirmation method

## Scope
**In Scope:** All core types, Codable conformance, SwiftData @Model annotations
**Out of Scope:** Migration strategy, CloudKit sync
