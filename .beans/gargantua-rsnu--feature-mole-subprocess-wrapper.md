---
# gargantua-rsnu
title: 'Feature: Mole Subprocess Wrapper'
status: completed
type: feature
priority: high
tags:
    - area:backend
    - pasiv
created_at: 2026-04-15T00:45:44Z
updated_at: 2026-04-15T11:06:58Z
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

## Summary of Changes

All tasks completed:
- gargantua-t6wk: MoleRunner subprocess wrapper with timeout, crash detection, binary path resolution
- gargantua-obof: MoleOutputParser for JSON→ScanResult conversion with category→safety mapping

The Mole Subprocess Wrapper feature is complete: process execution → JSON parsing → typed ScanResult models.
