---
# gargantua-n4jn
title: 'Feature: Dashboard MCP server status widget'
status: todo
type: feature
priority: normal
created_at: 2026-04-23T20:54:27Z
updated_at: 2026-04-23T20:54:27Z
---

Surface MCP server state on the Dashboard so users can see whether the server is running and who is connected. Closes a Phase 2 dashboard gap from PRD §5.4.

## Context

PRD §5.4 Dashboard spec calls for an "MCP Server Status" tile showing running/stopped state and connected clients. Dashboard ships but doesn't expose MCP visibility today.

## Requirements

- State: running / stopped / error (with last error message)
- Transport mode (stdio today; SSE later)
- Connected clients: count + list of client identifiers from current sessions
- Start / Stop toggle (with confirmation since stopping disconnects active clients)
- Link to audit log filter for MCP-originated actions

## Todo

- [ ] Expose server state + client list from GargantuaMCP as an observable
- [ ] DashboardView tile design + wiring
- [ ] Start/Stop action with SMAppService gating if the server runs as an agent
- [ ] "Recent MCP actions" mini-log on hover/expand
- [ ] Unit/snapshot tests for each state
