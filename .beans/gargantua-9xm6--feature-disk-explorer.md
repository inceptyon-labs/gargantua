---
# gargantua-9xm6
title: 'Feature: Disk Explorer'
status: todo
type: feature
priority: normal
tags:
    - area:frontend
    - pasiv
created_at: 2026-04-15T00:46:20Z
updated_at: 2026-04-15T00:46:20Z
parent: gargantua-aek3
---

Sorted expandable list of disk consumers with size bars. Progressive loading for drill-down.

## Goals
- Show top-level disk consumers immediately
- Drill-down loads child directories on expand
- Permission-denied paths grayed with "Requires Full Disk Access" inline
- Size bars provide visual proportion at a glance

## Scope
**In Scope:** Sorted list, size bars, expand/collapse, progressive loading, permission-denied indicators
**Out of Scope:** Treemap visualization (Phase 2), file type breakdown
