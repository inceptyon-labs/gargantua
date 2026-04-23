---
# gargantua-u9il
title: 'Feature: MCP clean tool handler'
status: todo
type: feature
priority: high
created_at: 2026-04-23T20:54:06Z
updated_at: 2026-04-23T21:10:15Z
parent: gargantua-rght
---

Add the `clean` tool to the MCP server so agents can execute cleanup, not just scan/analyze. **Phase 3** feature from PRD §7.3 + §7.4 + §10 (v2 roadmap). Child of `gargantua-rght` (MCP Server v2 epic).

## Context

PRD §10 line 898 scopes the clean tool to Phase 3 alongside full agent integration. `MCPToolDescriptor.swift:151` documents the intentional split: Phase 2 tools are read-only/dry-run, and destructive capabilities live in a distinct Phase 3 registry so Phase 2 paths can't accidentally advertise them.

This is the core of the MCP v2 epic. Tier 3 agent integration (`gargantua-5e10`) depends on it.

## Child tasks (sequential)

Scope is large enough that implementation is decomposed into four sequential tasks:

1. **`gargantua-0c7z`** — Task: MCP Phase 3 tool registry + clean descriptor/schema
2. **`gargantua-53q1`** — Task: MCPCleanToolHandler + scan-session cache + core safety *(blocked by 0c7z)*
3. **`gargantua-afft`** — Task: MCP client ID plumbing, audit wiring, rate limiter *(blocked by 53q1)*
4. **`gargantua-uxdr`** — Task: MCP clean user notification, integration test, docs *(blocked by afft)*

Each child owns its own testing + review cycle. This feature bean closes when all four are merged.

## Tool contract (PRD §7.3)

- Tool name: `clean`, registered in a new `MCPPhase3Tools` registry — NOT in `MCPPhase2Tools.all`
- Input: `item_ids: [String]`, `method: "trash" | "delete"` (default `trash`), `confirm: true` (must be literal true)
- Returns: `{ cleaned: Int, freed: String, method: String, audit_id: String, per_item: [...] }`
- Dry-run mode (`dry_run: true`) returns the plan without touching the filesystem

## Safety guardrails (PRD §7.4)

- **Protected items:** hard reject server-side based on YAML classification. AI cannot lower the floor.
- **Review items:** require `confirm: true` in the call. Reject with `invalidParams` otherwise.
- **Rate limit:** max 1 clean operation per 60 seconds per client identifier.
- **User notification:** macOS notification on every MCP-initiated clean with a Cancel action (time-bounded grace) before the operation begins.
- **Audit trail:** log entry includes `transport: "mcp"` and `client_id: <identifier>`.
- **Item IDs must come from a prior scan** — resolve through a scan-session cache; reject unknown IDs.

## Architectural split

Clean tool lives in `MCPPhase3Tools` (new type) and is registered only in Phase 3 code paths. The existing Phase 2 server entry point stays read-only; a Phase 3 entry point (or a feature flag) opts into Phase 3 tools.
