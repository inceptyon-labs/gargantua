---
# gargantua-0c7z
title: 'Task: MCP Phase 3 tool registry + clean descriptor/schema'
status: in-progress
type: task
priority: high
created_at: 2026-04-23T21:09:36Z
updated_at: 2026-04-23T21:11:29Z
parent: gargantua-u9il
---

First child of `gargantua-u9il`. Establishes the Phase 3 MCP tool registry (distinct from Phase 2) and defines the `clean` tool's descriptor + input/output schemas per PRD §7.3.

## Scope

Foundation only — no handler logic, no cleanup execution. Just the types and registration points so later children have somewhere to plug in.

## Todo

- [x] Add `MCPPhase3Tools` enum/namespace parallel to `MCPPhase2Tools`, with `.all` collection
- [x] Define `clean` tool descriptor inside `MCPPhase3Tools`: name, description, input JSON schema per PRD §7.3
  - `item_ids: [string]` required
  - `method: "trash" | "delete"` optional, default trash
  - `confirm: boolean` required, must be literal true (use `const: .bool(true)`)
  - `dry_run: boolean` optional, default false
- [x] Add `MCPToolName.clean` case so the descriptor can reference it
- [x] Define `MCPCleanInput` Codable struct matching the schema (rejects `confirm != true` at decode)
- [x] Define `MCPCleanOutput` Codable struct: `cleaned: Int`, `freed: String`, `method: String`, `audit_id: String`, `per_item: [MCPCleanItemResult]`
- [x] Define `MCPCleanItemResult`: `id`, `outcome: "moved" | "skipped" | "failed"`, optional `reason`, optional `bytes_freed`
- [x] Unit tests for the schema: confirm const-true rejection, method enum validation, required fields, round-trip encode/decode
- [x] No dispatcher registration yet — that happens in Task 2 when the handler exists

## Non-goals

- Handler implementation (Task 2)
- Scan-session cache (Task 2)
- Audit / rate limit / notification (Tasks 3–4)
- Phase 3 server entry point (Task 4 docs/integration)
