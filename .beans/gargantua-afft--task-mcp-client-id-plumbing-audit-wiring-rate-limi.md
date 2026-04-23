---
# gargantua-afft
title: 'Task: MCP client ID plumbing, audit wiring, rate limiter'
status: in-progress
type: task
priority: high
created_at: 2026-04-23T21:09:58Z
updated_at: 2026-04-23T22:05:48Z
parent: gargantua-u9il
blocked_by:
    - gargantua-53q1
---

Third child of `gargantua-u9il`. Wires the Phase 3 infrastructure requirements from PRD §7.4: client identification end-to-end, audit entries for MCP-initiated operations, and rate limiting shared across future destructive Phase 3 tools.

## Dependencies

Blocked by Task 2 (needs a working handler to attach this infra to).

## Scope

- Client identifier plumbing: transport → dispatcher → handler → audit
- AuditWriter integration with `transport: "mcp"` + `client_id` fields
- Rate limiter enforcing max 1 clean per 60s per client identifier
- Designed so the rate limiter is reusable for any future Phase 3 destructive tool

## Todo

- [x] Extend `MCPRequestDispatcher` (or the transport layer) to surface a client identifier per request — source depends on transport (stdio initialize handshake metadata for now; SSE bearer-token subject later under `gargantua-vdeg`)
- [x] Pass the client identifier through to tool handlers via the existing handler context or a new parameter
- [x] Extend `AuditEntry` (or provide an MCP-specific variant) with `transport: "mcp"` and `client_id: String`
- [x] Wire `MCPCleanToolHandler` to write an audit entry via `AuditWriter` on both success and failure paths; surface `audit_id` in `MCPCleanOutput`
- [x] Implement `MCPRateLimiter` (value type or actor) with per-client, per-tool sliding-window enforcement (1 op / 60s default, configurable)
- [x] Gate `MCPCleanToolHandler` behind the rate limiter; return `invalidParams` with a clear "cool-down active, retry in Ns" message when tripped
- [x] Unit tests: audit entry shape (transport/client_id present), audit_id round-trips to output, rate limiter allows first call + rejects second inside window, rate limiter scoped per-client (client A doesn't starve client B), rate limiter recovers after window

## Non-goals

- User-facing notification with Cancel (Task 4)
- Integration test via real stdio (Task 4)
- Bearer-token-derived client ID for SSE (lives under `gargantua-vdeg`)
