---
# gargantua-6an3
title: 'Task: Define stdio MCP server target and tool schemas'
status: in-progress
type: task
priority: high
created_at: 2026-04-17T18:07:39Z
updated_at: 2026-04-17T22:01:15Z
parent: gargantua-2h06
---

Add the executable target shape and concrete JSON schemas for PRD Phase 2 MCP tools: scan, analyze, explain, list_profiles, and status. Keep scan dry-run only.


## Plan

Scope: define executable target + Codable tool schemas (Phase 2, stdio). No dispatch logic yet.

### Todos
- [x] Add GargantuaMCP executable target to Package.swift
- [x] Create Sources/GargantuaMCP/main.swift stub (not-implemented notice)
- [x] Create Sources/GargantuaCore/Models/MCP/MCPToolDescriptor.swift (tool registry + JSON Schema descriptor)
- [x] Create Sources/GargantuaCore/Models/MCP/MCPToolSchemas.swift (Codable input/output for scan, analyze, explain, list_profiles, status; scan.dry_run always true)
- [x] Tests: encoding round-trip + enforce scan dry-run invariant
- [x] Verification gate (tests, build, lint)


## Summary of Changes

Defined the Phase 2 MCP server target shape and Codable tool schemas per PRD §7.3.

**Files added**
- `Package.swift` — added `GargantuaMCP` executable target + product
- `Sources/GargantuaMCP/main.swift` — stub entrypoint that emits the tool catalog (to be replaced with JSON-RPC dispatch in a follow-up task)
- `Sources/GargantuaCore/Models/MCP/MCPToolDescriptor.swift` — `MCPToolName`, `MCPToolDescriptor`, `MCPJSONSchema`, `MCPJSONValue`, and `MCPPhase2Tools` registry
- `Sources/GargantuaCore/Models/MCP/MCPToolSchemas.swift` — Codable input/output types for `scan`, `analyze`, `explain`, `list_profiles`, `status`
- `Tests/GargantuaCoreTests/Models/MCP/MCPToolSchemasTests.swift` — 18 tests covering registry contents, schema invariants, decode rejection of `dry_run=false`, `explain` mutual-exclusion, and snake_case round-trips

**Key decisions**
- `scan` enforces dry-run at the type boundary: `MCPScanInput.init(from:)` rejects `dry_run=false`; the JSON Schema pins the property to `const: true`. No `clean` tool is registered in `MCPPhase2Tools`, so Phase 2 code cannot surface destructive capabilities.
- `explain` requires exactly one of `path` or `item_id`; the custom decoder rejects empty and both-set payloads.
- Tool-level size/date fields are strings matching the PRD example payload; the richer byte-level data stays on the internal `ScanResult`.
- Output types have per-struct `CodingKeys` mapping Swift camelCase to the wire-format snake_case (`total_reclaimable`, `health_score`, `top_consumers`, `safe_count`, `last_accessed`).

**Notes for next task**
- `Sources/GargantuaMCP/main.swift` currently writes JSON to stdout; the JSON-RPC framing task must replace this with stdio message framing (stdout is reserved for protocol messages).
- `MCPPhase2Tools.all` is the canonical input for a future `tools/list` handler.
- `MCPAnalyzeOutput` has no in-process producer yet; it will be populated from `SystemMetricCollector` + disk usage summary.
- `MCPStatusOutput` can be built from the existing `SystemMetrics` struct (map percent fields × 100, format bytes to strings).

**Tests**: 353/353 passing (baseline 335 + 18 new).
