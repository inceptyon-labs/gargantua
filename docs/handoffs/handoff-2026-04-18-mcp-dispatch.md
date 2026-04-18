# Session Handoff: MCP protocol dispatch

Date: 2026-04-18
Task completed: gargantua-tr4w — "Task: MCP tools/list + tools/call dispatch"
Parent: gargantua-2h06 (Feature: MCP Server v1) → gargantua-qe4a (Epic: Phase 2 Intelligence)

## What Was Done

Implemented `MCPRequestDispatcher` on top of the stdio framing layer. Phase 2 MCP clients can now:

- `initialize` — handshake returns protocolVersion, server-advertised `tools` capability, and serverInfo. Requires client-side `protocolVersion` param.
- `tools/list` — advertises all five Phase 2 tools (`scan`, `analyze`, `explain`, `list_profiles`, `status`) with their JSON Schemas. `scan.dry_run` const=true is preserved on the wire.
- `tools/call` — routes by `MCPToolName` to registered handlers. No handlers are registered yet; every call currently returns `-32603 Tool not implemented`.

All five follow-up Tasks will just call `dispatcher.register(tool: .scan) { args in ... }` and return an `MCPToolCallResult`.

## Files Changed

- `Sources/GargantuaCore/Services/MCP/MCPRequestDispatcher.swift` (new, 440 lines)
- `Sources/GargantuaMCP/main.swift` (dispatcher wiring, stderr log hook)
- `Tests/GargantuaCoreTests/Services/MCP/MCPRequestDispatcherTests.swift` (new, 29 tests)
- `docs/handoffs/archive/handoff-2026-04-18-mcp-jsonrpc-framing.md` (archived prior handoff)

Baseline 498 → 527 tests (all passing). `swift build -Xswiftc -warnings-as-errors` clean.

## Key Decisions (the ones that matter for next Tasks)

- **Handler signature:** `@Sendable (MCPToolArguments) throws -> MCPToolCallResult`.
  - Arguments come in as a validated `[String: MCPJSONAny]` with a `decode<T: Decodable>(_:)` helper that throws `MCPToolError.invalidParams` on failure.
  - Return an `MCPToolCallResult` — use `.text(...)`, `.structured(payload, summary: ...)`, or `.failure(...)` depending on shape.
- **Result envelope is MCP-compliant** (`{content: [...], structuredContent?, isError?}`), not raw JSON. This was a Codex Pass 2 catch; earlier drafts returned the handler's raw MCPJSONAny and would have broken real MCP clients.
- **Tool-domain failures go in `isError: true`, not JSON-RPC error.** A scan that finds nothing, an explain on a missing path, a status that can't reach sysctl — all should return `.failure(...)`, not throw. JSON-RPC errors are reserved for protocol-level problems (malformed call, unknown method, tool not wired).
- **`tools/call.arguments` is validated as object-or-absent** before any handler runs. Don't need to revalidate in handlers.
- **Generic exceptions don't leak to clients.** If a handler throws something other than `MCPToolError`, the client sees "Internal error: Tool execution failed" and the detail goes to stderr. Only throw `MCPToolError.invalidParams` / `.internalError` with a sanitised message if you want the client to see the text.
- **Error-code mapping:**
  - Unknown method → -32601
  - Unknown tool name / malformed params / non-object arguments / handler `.invalidParams` → -32602
  - Tool not registered / handler `.internalError` / generic exception → -32603
- **Dispatcher is Sendable-safe** (NSLock-guarded handler map). Registration and dispatch can race without issue.

## Next Steps (ordered)

All four remaining tasks under Feature `gargantua-2h06` now unblocked; `tr4w` is completed. Priority order per their files:

1. **gargantua-sbg6** — `scan` tool handler (dry-run enforced). Wire to ScanEngine / SafetyClassifier. Use `arguments.decode(MCPScanInput.self)` to get `profile`, `categories`, `dryRun` (already enforced `true` at decode). Shape output per `MCPScanOutput`. Return as `.structured(...)`.
2. **gargantua-2xod** — `analyze` + `status` tool handlers. Wire through `SystemMetricCollector`. `analyze` → `MCPAnalyzeOutput`, `status` → `MCPStatusOutput`.
3. **gargantua-o4ef** — `explain` + `list_profiles` tool handlers. `MCPExplainInput` already enforces path-xor-item_id at decode.
4. **gargantua-2h06** itself closes once its four child Tasks are done.

Each follow-up Task is small — mostly wiring + encoding. The dispatcher contract is stable.

## Files to Load Next Session

- `Sources/GargantuaCore/Services/MCP/MCPRequestDispatcher.swift` — the contract the next handlers plug into (especially `MCPToolHandler`, `MCPToolArguments.decode`, `MCPToolCallResult`)
- `Sources/GargantuaCore/Models/MCP/MCPToolSchemas.swift` — the `MCPScanInput/Output`, `MCPExplainInput/Output`, etc. already defined
- `Sources/GargantuaMCP/main.swift` — where `dispatcher.register(tool: .scan) { ... }` calls will land
- For gargantua-sbg6 specifically: whatever service provides scan results (likely `ScanEngine` / `SafetyClassifier`)

## What NOT to Re-Read

- `Sources/GargantuaCore/Services/MCP/MCPStdioTransport.swift` — framing is done, stable.
- `Sources/GargantuaCore/Models/MCP/MCPJSONRPC.swift` — JSON-RPC types are done.
- `Sources/GargantuaCore/Models/MCP/MCPToolDescriptor.swift` — registry is done, stable.
- `Tests/GargantuaCoreTests/Services/MCP/MCPRequestDispatcherTests.swift` — dispatcher coverage done; next tests go in per-tool test files.

## Reference

- PRD §7.3 (tool shapes) and §7.4 (safety guardrails — especially scan dry-run)
- Completed child-task summary: `.beans/gargantua-tr4w--task-mcp-toolslist-toolscall-dispatch.md` → "Summary of Changes"
