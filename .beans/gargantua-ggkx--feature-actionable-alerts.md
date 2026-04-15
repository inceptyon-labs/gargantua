---
# gargantua-ggkx
title: 'Feature: Actionable Alerts'
status: completed
type: feature
priority: high
tags:
    - area:frontend
    - pasiv
created_at: 2026-04-15T00:45:58Z
updated_at: 2026-04-15T18:43:43Z
parent: gargantua-qne2
---

Dense alert list showing specific reclaimable amounts with click-through to relevant scan screens.

## Goals
- Alerts are declarative: "23 GB of stale dev artifacts (>30 days)" — no marketing language
- Each alert links to the relevant scan screen (Deep Clean, Dev Purge, etc.)
- Quick Scan button triggers active profile and shows inline progress

## Scope
**In Scope:** Alert list, reclaimable size calculation, click-through navigation, Quick Scan button with progress
**Out of Scope:** Alert configuration, notification scheduling
