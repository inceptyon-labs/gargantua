---
# gargantua-jj6r
title: 'Feature: Mole Command Adapters'
status: todo
type: feature
priority: high
tags:
    - area:backend
    - pasiv
created_at: 2026-04-15T00:45:44Z
updated_at: 2026-04-15T00:45:44Z
parent: gargantua-q0og
---

Typed adapters for mo clean, mo purge, mo analyze, and mo status. Maps Mole output to ScanResult models with Trust Layer metadata.

## Goals
- Consistent ScanResult output regardless of which mo command produced it
- Trust Layer mapping assigns safety levels to Mole categories
- Progress reporting through unified ScanProgress observable

## Scope
**In Scope:** mo clean adapter, mo purge adapter, mo analyze adapter, mo status --json adapter, category-to-safety mapping
**Out of Scope:** mo update, A/B comparison with native scanner (Phase 1.5)
