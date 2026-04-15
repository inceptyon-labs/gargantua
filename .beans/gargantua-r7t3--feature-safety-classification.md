---
# gargantua-r7t3
title: 'Feature: Safety Classification'
status: todo
type: feature
priority: critical
tags:
    - area:backend
    - pasiv
created_at: 2026-04-15T00:45:35Z
updated_at: 2026-04-15T00:45:35Z
parent: gargantua-6v1k
---

SafetyLevel assignment and confirmation tiers. Every item gets safe/review/protected with confidence scoring.

## Goals
- Deterministic classification from YAML rules — never from AI
- Profile overrides (Developer profile auto-classifies stale dev artifacts as safe)
- Confirmation UX scales with risk: single button for all-safe, full modal for protected

## Scope
**In Scope:** SafetyLevel enum, classification logic, confidence scoring, profile overrides, confirmation tier routing
**Out of Scope:** AI classification advisory (that's in AI Tier 1)
