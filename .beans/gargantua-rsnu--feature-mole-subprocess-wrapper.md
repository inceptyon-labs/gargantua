---
# gargantua-rsnu
title: 'Feature: Mole Subprocess Wrapper'
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

Process-based Mole execution with timeout, crash isolation, and JSON output parsing.

## Goals
- Each Mole command runs in its own Process with configurable timeout
- Crash or hang → catch, log, disable feature with visible warning, continue operating
- Bundled mo binary signed with same team ID as parent app

## Scope
**In Scope:** Process wrapper, timeout handling, crash recovery, JSON parsing, TCC inheritance verification
**Out of Scope:** Mole version auto-update, Mole CLI installation
