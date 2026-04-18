# Session Handoff: MCP JSON-RPC stdio framing

Date: 2026-04-18
Task completed: gargantua-xc7m — "Task: MCP JSON-RPC 2.0 stdio framing"
Parent: gargantua-2h06 (Feature: MCP Server v1) → gargantua-qe4a (Epic: Phase 2 Intelligence)

## What Was Done

1. **Triage**: Audited the four open Phase 2 Features (Duplicate Finder, File Health, MCP Server v1, Developer Tools). Each had only its plumbing-layer Task complete; none were user-visible. Created 10 concrete follow-up Tasks so the `/kick` queue is actionable. Committed as `8fcad38`.
2. **Implemented gargantua-xc7m**: JSON-RPC 2.0 newline-delimited framing for the stdio MCP server. Framing-only — dispatch lives in the next Task. Merged to main.

## Files Changed

- `.beans/*` — 10 new child Tasks + status on `xc7m`
- `Sources/GargantuaCore/Models/MCP/MCPJSONRPC.swift` (new)
- `Sources/GargantuaCore/Services/MCP/MCPStdioTransport.swift` (new)
- `Sources/GargantuaMCP/main.swift` (rewritten)
- `Tests/GargantuaCoreTests/Models/MCP/MCPJSONRPCTests.swift` (new, 19 tests)
- `Tests/GargantuaCoreTests/Services/MCP/MCPStdioTransportTests.swift` (new, 18 tests)

Baseline 461 tests → 498 tests (all passing).

## Key Decisions

- **Line framing**: newline-delimited JSON per MCP spec (not LSP Content-Length).
- **Key-presence semantics**: `MCPRequest` and `MCPResponse` use `c.contains(.key)` rather than `decodeIfPresent` so `{"result": null}` decodes as success-with-null, not as empty response. Applied to `id`, `params`, `result`, `error`.
- **Encode-failure fallback**: `emit(_:fallbackID:)` always leaves the client with a response; a handler that returns a non-encodable payload (e.g., `Double.infinity`) triggers a guaranteed-safe internal-error fallback.
- **Log hygiene**: control characters in malformed input are escaped (`\uXXXX`) and the log excerpt is capped at 512 chars; applied to the full log message so Cocoa-originated `NSDebugDescription` text is also sanitized.
- **`@Sendable` typealiases**: `MCPMessageHandler` and `MCPTransportLog` are `@Sendable` so a future concurrency wrapping does not surface late.
- **Dispatch scope**: deliberately excluded. Default handler returns `method not found` for every request.

## Next Steps (ordered)

Next Tasks under Feature `gargantua-2h06` (MCP Server v1):

1. **gargantua-tr4w** — MCP `tools/list` + `tools/call` dispatch (blocked-by `xc7m`, now unblocked). Replace the default method-not-found handler with a dispatcher keyed by `MCPToolName` plus protocol methods (`initialize`, `tools/list`, `tools/call`). Round-trip `MCPJSONAny` params through `JSONEncoder`/`JSONDecoder` to decode into the typed `MCPScanInput` / `MCPExplainInput` etc. structs from `MCPToolSchemas.swift`.
2. **gargantua-sbg6** — `scan` tool handler (dry-run enforced).
3. **gargantua-2xod** — `analyze` + `status` handlers (SystemMetricCollector wiring).
4. **gargantua-o4ef** — `explain` + `list_profiles` handlers.

All four are blocked by `xc7m`, which is now completed. `tr4w` should be picked up next.

## Files to Load Next Session

- `Sources/GargantuaCore/Models/MCP/MCPJSONRPC.swift` — the framing types the dispatcher will build on
- `Sources/GargantuaCore/Services/MCP/MCPStdioTransport.swift` — where the handler closure is installed
- `Sources/GargantuaCore/Models/MCP/MCPToolDescriptor.swift` — `MCPToolName`, `MCPPhase2Tools.all`
- `Sources/GargantuaCore/Models/MCP/MCPToolSchemas.swift` — `MCPScanInput/Output`, `MCPExplainInput/Output`, etc.
- `Sources/GargantuaMCP/main.swift` — the entry point whose handler will be swapped out

## What NOT to Re-Read

- `Tests/GargantuaCoreTests/Models/MCP/MCPJSONRPCTests.swift` — framing tests done
- `Tests/GargantuaCoreTests/Services/MCP/MCPStdioTransportTests.swift` — transport tests done
- Other Phase 2 Feature beans (4nb9, 0q30, 7hdn) — untouched by this task

## Reference

- PRD §7 MCP Server (esp. §7.3 tool specs, §7.4 safety guardrails)
- Completed child-task summary: `.beans/gargantua-xc7m--task-mcp-json-rpc-20-stdio-framing.md` → "Summary of Changes"
