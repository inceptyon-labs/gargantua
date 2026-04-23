---
# gargantua-iqzg
title: 'Task: Wire custom cleanup profiles through MCP'
status: todo
type: task
priority: normal
created_at: 2026-04-23T20:54:20Z
updated_at: 2026-04-23T20:54:20Z
---

Remove the "custom profile not supported via MCP" stub so agents can use user-defined profiles, not just the three built-ins.

## Context

Sources/GargantuaMCP/main.swift currently throws `MCPToolError.invalidParams("'custom' profile is not yet supported via MCP; use 'developer', 'light', or 'deep'.")` when a request passes a custom profile name. GUI side already persists and applies custom profiles.

## Todo

- [ ] Resolve profile by name through the same store the GUI uses (not a hardcoded switch)
- [ ] MCP `list_profiles` includes custom profiles with their identifiers
- [ ] Pass custom profile IDs through scan/analyze/clean tool inputs
- [ ] Graceful error when an unknown profile ID is passed
- [ ] Tests: built-in + custom profile resolution, unknown ID error shape
