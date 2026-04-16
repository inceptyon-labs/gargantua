---
# gargantua-q0og
title: 'Epic: Mole Integration'
status: completed
type: epic
priority: high
tags:
    - area:backend
    - pasiv
created_at: 2026-04-15T00:44:28Z
updated_at: 2026-04-16T02:19:29Z
---

Phase 1 scanning via Mole subprocess. Wraps mo clean, mo purge, mo analyze, and mo status with Trust Layer mapping. Short-lived dependency — native scanner replaces it in Phase 1.5/2.

## Vision
Ship fast with Mole's battle-tested domain knowledge while mapping its output to our Trust Layer. Each command runs in its own Process with timeout and failure isolation.

## Features
- Mole subprocess wrapper with timeout and crash isolation
- JSON output parsing into ScanResult models
- Trust Layer safety mapping from Mole categories
- Command adapters: clean, purge, analyze, status

## Success Criteria
- [ ] Mole binary bundled and signed with same team ID
- [ ] All four commands produce typed ScanResult output
- [ ] Subprocess crash/timeout caught and logged without app crash
- [ ] Trust Layer mapping assigns correct safety levels

## Summary of Changes\n\nAll child features completed:\n- Mole Subprocess Wrapper (gargantua-rsnu): MoleRunner with timeout, crash isolation, JSON parsing\n- Mole Command Adapters (gargantua-jj6r): mo clean, purge, analyze, status adapters with Trust Layer mapping
