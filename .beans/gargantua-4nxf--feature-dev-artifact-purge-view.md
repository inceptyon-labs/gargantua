---
# gargantua-4nxf
title: 'Feature: Dev Artifact Purge View'
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

Dev-specific scan screen reusing the three-bucket pattern. Categories: node_modules, build artifacts, simulator caches, Docker images, Homebrew.

## Goals
- Reuse scan results pattern with dev-specific categories
- Profile-aware overrides: Developer profile auto-classifies stale artifacts as safe
- Category breakdown shows which dev tools consume the most space

## Scope
**In Scope:** Category-based scan view, profile override display, reuse of scan results components
**Out of Scope:** Homebrew/Docker interactive commands (Phase 2)
