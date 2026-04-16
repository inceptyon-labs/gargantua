---
# gargantua-gae9
title: 'Feature: Scan Rules & Whitelist'
status: completed
type: feature
priority: normal
tags:
    - area:frontend
    - pasiv
created_at: 2026-04-15T00:46:33Z
updated_at: 2026-04-16T10:55:35Z
parent: gargantua-w7pe
---

YAML rule viewer and whitelist editor. Transparency — users can see exactly what rules drive every classification.

## Goals
- View YAML rules with syntax highlighting
- Whitelist management: add paths/patterns to skip during scans
- Whitelist persists and is respected by all scan engines

## Scope
**In Scope:** Read-only rule viewer, whitelist add/remove, whitelist persistence
**Out of Scope:** Rule editing in-app, community rule updates

## Summary of Changes\n\nChild task completed: gargantua-2xke (profile list and editor)
