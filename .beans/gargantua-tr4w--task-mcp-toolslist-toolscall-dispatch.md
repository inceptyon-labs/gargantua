---
# gargantua-tr4w
title: 'Task: MCP tools/list + tools/call dispatch'
status: completed
type: task
priority: high
created_at: 2026-04-18T22:18:34Z
updated_at: 2026-04-18T22:58:35Z
parent: gargantua-2h06
blocked_by:
    - gargantua-xc7m
---

Implement MCP protocol dispatch: initialize handshake, tools/list returning MCPPhase2Tools.all, tools/call routing by MCPToolName. Unknown tools return proper JSON-RPC error. Reference: MCPToolDescriptor.swift MCPPhase2Tools, MCPToolSchemas.swift.


## Summary of Changes

Implemented MCP protocol dispatch over the stdio transport that landed in gargantua-xc7m. Phase 2 handshake, tool discovery, and tool invocation now all work; actual tool handlers land in the next Tasks.

### Files

- `Sources/GargantuaCore/Services/MCP/MCPRequestDispatcher.swift` (new) — dispatcher, tool-handler contract, CallToolResult envelope, error mapping.
- `Sources/GargantuaMCP/main.swift` — constructs dispatcher, wires stderr log into both dispatcher and transport.
- `Tests/GargantuaCoreTests/Services/MCP/MCPRequestDispatcherTests.swift` (new) — 29 tests.

### Public API surface added

- `MCPRequestDispatcher` — `init(serverInfo:protocolVersion:tools:log:)`, `register(tool:handler:)`, `dispatch(_:) -> MCPResponse?`.
- `MCPToolHandler = @Sendable (MCPToolArguments) throws -> MCPToolCallResult`.
- `MCPToolArguments` — validated `[String: MCPJSONAny]`; `decode<T: Decodable>(_:)` helper.
- `MCPToolCallResult` — MCP-compliant `{content, structuredContent?, isError?}`; convenience factories `.text(...)`, `.structured(...,summary:)`, `.failure(...)`.
- `MCPToolContent` — `.text(String)` (image/resource deferred).
- `MCPToolError` — `.invalidParams(String)` → -32602, `.internalError(String)` → -32603 when thrown by handlers.
- `MCPServerInfo` — name/version carried into the initialize handshake.
- `MCPDispatcherLog = @Sendable (String) -> Void` — optional stderr hook for operator-only diagnostic output.

### Key decisions

- **CallToolResult envelope per MCP spec:** Handlers return `MCPToolCallResult`, not raw JSON. Structured payloads ride in `structuredContent`; a text `content` block is always present so clients that don't parse `structuredContent` still get a human-readable message. (Codex Pass 2 catch.)
- **Tool-domain failures return `isError: true`, not a JSON-RPC error.** Reserves the JSON-RPC error slot for protocol-level problems (malformed call, unknown method, tool not wired). (MCP spec §tools/call.)
- **`tools/call.arguments` must be object-or-absent.** Explicit null, arrays, and scalars are rejected with -32602 before reaching a handler. (Codex Pass 2 catch.)
- **Generic exceptions don't leak to the client.** Only `MCPToolError.invalidParams`/`internalError` messages cross the boundary verbatim; anything else becomes a generic "Tool execution failed" with details logged to stderr. Avoids path/identity leakage from future handlers. (Codex Pass 2 catch.)
- **`initialize` params required.** `protocolVersion` must be present; `capabilities` and `clientInfo` accepted loosely. Strict version negotiation deferred. (Codex Pass 2 catch.)
- **Error-code mapping:**
  - Unknown method → -32601 (MethodNotFound)
  - Unknown tool name / malformed params / non-object arguments → -32602 (InvalidParams)
  - Known tool but no handler registered → -32603 (InternalError: "Tool not implemented")
  - Handler throws `MCPToolError.invalidParams` → -32602
  - Handler throws `MCPToolError.internalError` → -32603
  - Handler throws anything else → -32603 with generic message
- **Notification short-circuit.** Notifications (id absent) return `nil` before invoking tool handlers, so malformed notification-form `tools/call` can't accidentally run a tool with unchecked arguments.
- **`MCPToolArguments.decode(T.self)` helper** returns a `Decodable` struct; decode failures throw `MCPToolError.invalidParams`, which the dispatcher maps to -32602. Upcoming handlers (`gargantua-sbg6` scan, `gargantua-2xod` analyze/status, `gargantua-o4ef` explain/list_profiles) use this to turn arguments into `MCPScanInput` / `MCPExplainInput` / etc.

### Review

- SC tier. Sonnet Pass 1 clean. Codex Pass 2 found 2 ERRORs (result envelope, arguments validation) and 2 WARNINGs (initialize params, error sanitisation); all fixed before merge.

### Test counts

498 baseline → 527 (29 new dispatcher tests).
