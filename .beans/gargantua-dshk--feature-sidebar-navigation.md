---
# gargantua-dshk
title: 'Feature: Sidebar Navigation'
status: todo
type: feature
priority: high
tags:
    - area:frontend
    - pasiv
created_at: 2026-04-15T00:45:12Z
updated_at: 2026-04-15T00:45:12Z
parent: gargantua-0jj3
---

Grouped sidebar with sections: CLEAN (Deep Clean), ANALYZE (Disk Explorer), TOOLS (Dev Artifact Purge, Homebrew, Docker), CONFIGURE (Settings). System badge at bottom.

## Goals
- Navigation teaches users how to think about the app's capabilities
- Keyboard-first: Cmd+1-5 for sections, Cmd+, for Settings
- Active state: --surface-2 background + 2px --accent left indicator

## Scope
**In Scope:** Grouped sections with uppercase labels, SF Symbol icons, active/hover states, keyboard shortcuts, system badge (macOS version + disk free)
**Out of Scope:** Collapsible sidebar, drag-to-reorder
