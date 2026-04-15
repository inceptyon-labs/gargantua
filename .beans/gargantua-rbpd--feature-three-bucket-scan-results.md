---
# gargantua-rbpd
title: 'Feature: Three-Bucket Scan Results'
status: todo
type: feature
priority: high
tags:
    - area:frontend
    - pasiv
created_at: 2026-04-15T00:46:20Z
updated_at: 2026-04-15T00:46:20Z
parent: gargantua-aek3
---

The universal scan results pattern: Safe (expanded, pre-selected), Review (expanded, not selected), Protected (shown, locked). Dense item rows with all data visible.

## Goals
- All data visible: name, size (monospace right-aligned), file path, confidence orbit, explanation
- Three-bucket headers show count and total size
- Select/deselect with keyboard (Space, Cmd+A for safe items)

## Scope
**In Scope:** Bucket layout, item row component, confidence orbit element, select/deselect, hover explain button, right-click context menu
**Out of Scope:** Filtering, sorting, search within results
