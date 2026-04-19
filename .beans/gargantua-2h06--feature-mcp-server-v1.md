---
# gargantua-2h06
title: 'Feature: MCP Server v1'
status: completed
type: feature
priority: high
created_at: 2026-04-17T18:07:38Z
updated_at: 2026-04-19T01:53:56Z
parent: gargantua-qe4a
---

Implement PRD §7 Phase 2 MCP server v1 over stdio for Claude Code. Initial tools: scan, analyze, explain, list_profiles, status. Clean tool is Phase 3 unless explicitly pulled forward.


## Summary of Changes

All six child Tasks completed:
- `gargantua-xc7m`: MCP JSON-RPC 2.0 stdio framing
- `gargantua-6an3`: Define stdio MCP server target and tool schemas
- `gargantua-tr4w`: MCP tools/list + tools/call dispatch
- `gargantua-sbg6`: MCP scan tool handler (dry-run enforced)
- `gargantua-2xod`: MCP analyze + status tool handlers
- `gargantua-o4ef`: MCP explain + list_profiles tool handlers

All five Phase 2 tools (`scan`, `analyze`, `status`, `explain`, `list_profiles`) are now live in the stdio MCP server. `scan` is dry-run only (PRD §7.4 guardrail enforced at the `MCPScanInput` decode boundary). No `clean` tool is advertised — that is deferred to Phase 3 and intentionally absent from `MCPPhase2Tools.all`.

## Follow-Ups Carried Forward

- Schema `oneOf` for `explain.path`/`item_id` (Codex review gap: schema-driven clients can generate calls that runtime decode rejects).
- AI-backed `explain` provider (swap `MCPExplainToolHandler.defaultFilesystemProvider()` for an `AIInferenceEngine`-backed provider; handler/tests unchanged).
- Persisted profiles bridge (default `ProfilesProvider` returns built-ins; drops `'custom'` rejection in scan handler once wired).
- scan-backed `top_consumers` in the `analyze` output (currently empty `[]`).
