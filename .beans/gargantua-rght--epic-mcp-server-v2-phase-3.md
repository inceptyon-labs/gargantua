---
# gargantua-rght
title: 'Epic: MCP Server v2 (Phase 3)'
status: todo
type: epic
priority: high
created_at: 2026-04-23T21:05:56Z
updated_at: 2026-04-23T21:05:56Z
---

Phase 3 MCP server expansion. Per PRD §10 line 898: "MCP Server (v2 — clean tool + full agent integration)." Absorbs the Phase 3 transport work from §7.2 (SSE + bearer auth) and the destructive-tool guardrails from §7.4.

## Context

Phase 2 MCP server is deliberately read-only plus dry-run scan. Destructive capabilities and remote transports were held back to Phase 3 — see MCPToolDescriptor.swift:151: *"Exactly five tools are defined (PRD §7.3). No `clean` tool is present; any future Phase 3 registry should be a distinct value so Phase 2 code paths cannot accidentally advertise destructive capabilities."*

This epic is where Phase 3 MCP lands.

## Child scope

- **u9il** — Feature: MCP clean tool handler (child)
- **vdeg** — Feature: MCP SSE transport + bearer auth (child)
- **5e10** — AI Tier 3 Claude Code agent (consumer; already blocked-by u9il)
- **n4jn** — Dashboard MCP server status widget (logical sibling, kept standalone)

## Cross-cutting guardrails (PRD §7.4)

These are shared requirements across Phase 3 MCP tools; may be split into separate child beans if one child needs them before another:

- Protected items: hard server-side reject, regardless of client input
- Review items: require `confirm: true` in the call
- Rate limit: max 1 clean operation per 60 seconds per client
- User notification: macOS notification on every MCP-initiated clean with a Cancel grace period
- Audit trail: every MCP call tagged with transport=mcp + client identifier
- Architectural: Phase 3 tools live in a separate registry (e.g. `MCPPhase3Tools`) so Phase 2 paths can never leak destructive handlers

## Todo (epic-level)

- [ ] Define `MCPPhase3Tools` registry distinct from `MCPPhase2Tools.all`
- [ ] Ship child: u9il (MCP clean tool)
- [ ] Ship child: vdeg (SSE + bearer auth)
- [ ] Cross-cutting infra extracted if scope demands: rate limiter, client ID plumbing, user notification service
- [ ] Docs: update CONTRIBUTING/README with Phase 3 MCP tool list and safety notes
