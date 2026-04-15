---
# gargantua-38l5
title: 'Feature: First Launch Onboarding'
status: completed
type: feature
priority: normal
tags:
    - area:frontend
    - pasiv
created_at: 2026-04-15T00:45:18Z
updated_at: 2026-04-15T22:41:05Z
parent: gargantua-0jj3
---

Permission request flow on first launch. One screen per permission with clear explanation of what it unlocks. Skip always available, no guilt.

## Goals
- Build trust immediately — explain exactly what each permission enables
- Degrade gracefully — app works without FDA, just shows what's limited
- No nagging — if denied, show specific banners per affected feature

## Scope
**In Scope:** Full Disk Access request, Automation (Finder) request, permission-denied banners on relevant screens, "what this unlocks" explanations
**Out of Scope:** Network permission (optional, only for AI Tier 2/3)
