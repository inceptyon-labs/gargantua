---
# gargantua-5la2
title: 'Feature: YAML Rule System'
status: in-progress
type: feature
priority: critical
tags:
    - area:backend
    - pasiv
created_at: 2026-04-15T00:45:35Z
updated_at: 2026-04-15T11:11:05Z
parent: gargantua-6v1k
---

Declarative scan rules in YAML carrying Trust Layer metadata. The portable knowledge layer that bridges Mole (Phase 1) and the native scanner (Phase 2+).

## Goals
- Every rule carries safety level, confidence, explanation, source attribution
- Profile-aware overrides prevent Review bucket fatigue
- Rule files are human-readable, auditable, community-submittable

## Scope
**In Scope:** Rule schema definition, parser, initial rule set (browser, developer, system), profile overrides
**Out of Scope:** Community PR workflow, rule versioning strategy
