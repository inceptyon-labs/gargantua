---
# gargantua-vdeg
title: 'Feature: MCP SSE transport + bearer auth'
status: todo
type: feature
priority: normal
created_at: 2026-04-23T20:55:15Z
updated_at: 2026-04-23T21:06:12Z
parent: gargantua-rght
blocked_by:
    - gargantua-n4jn
---

Add Phase 3 MCP transport: Server-Sent Events over localhost with optional bearer token for non-localhost. From PRD §7.2.

## Context

PRD §7.2 specifies Phase 3 MCP transport: SSE on port 7493 by default, localhost-only by default, bearer token required if user exposes beyond localhost. Today only the stdio transport exists.

## Requirements

- SSE transport implementation alongside existing stdio (users pick one or run both)
- Port 7493 default; configurable in Settings
- Localhost binding by default; widen-to-LAN requires explicit toggle + bearer token
- Bearer token: generated once, shown once, stored in Keychain, rotate-on-demand
- CORS: disallow by default (MCP is not a browser API)
- Connection log visible in Dashboard MCP widget (ties into the dashboard-MCP-tile bean)

## Todo

- [ ] SSE server using URLSession / NIO (pick based on footprint)
- [ ] Transport abstraction so handlers stay transport-agnostic
- [ ] Keychain-backed bearer token generation + display UI
- [ ] Settings → MCP pane (port, bind address, token management)
- [ ] Localhost-only enforcement on the default bind
- [ ] Integration tests hitting the SSE endpoint with and without token
- [ ] Docs: example client configs (Claude Desktop, Cursor, Claude Code)
