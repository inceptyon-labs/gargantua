---
# gargantua-dshb
title: 'Feature: Audit Trail'
status: in-progress
type: feature
priority: high
tags:
    - area:backend
    - pasiv
created_at: 2026-04-15T00:45:35Z
updated_at: 2026-04-15T12:36:19Z
parent: gargantua-6v1k
---

Every destructive operation logged. Undo via Trash. 90-day retention.

## Goals
- Full audit: timestamp, tool used, command, files affected (paths + sizes), safety level, confirmation method
- Trash-first default enables undo for recent operations
- Configurable retention (default 90 days)

## Scope
**In Scope:** JSON audit log at ~/Library/Logs/Gargantua/audit.json, Trash-based undo, retention policy, audit log viewer in Settings
**Out of Scope:** Remote audit forwarding, audit analytics
