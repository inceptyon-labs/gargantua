---
# gargantua-yzi8
title: 'Feature: Clean Execution Flow'
status: todo
type: feature
priority: high
tags:
    - area:frontend
    - area:backend
    - pasiv
created_at: 2026-04-15T00:46:20Z
updated_at: 2026-04-15T00:46:20Z
parent: gargantua-aek3
---

Confirmation modal → Trash-based cleanup → post-clean summary. The highest-trust moment in the app.

## Goals
- Confirmation modal lists exact items, total size, method (Trash vs delete)
- Cancel is visually dominant escape route; destructive button uses --protected color
- Post-clean summary shows freed space and audit trail link
- Confirmation tiers: single button for all-safe, summary dialog for mixed, full modal for protected

## Scope
**In Scope:** Confirmation modal, Trash execution, audit trail integration, post-clean summary, confirmation tier routing
**Out of Scope:** Direct delete option (Trash-first for Phase 1)
