---
# gargantua-xc7m
title: 'Task: MCP JSON-RPC 2.0 stdio framing'
status: completed
type: task
priority: high
created_at: 2026-04-18T22:18:28Z
updated_at: 2026-04-18T22:37:55Z
parent: gargantua-2h06
blocked_by:
    - gargantua-6an3
---

Replace Sources/GargantuaMCP/main.swift stub with JSON-RPC 2.0 message framing over stdio (Content-Length-style or newline-delimited per MCP spec). stdout reserved for protocol messages; logging goes to stderr. No dispatch yet. Reference: main.swift stub, MCPToolDescriptor.swift.


## Summary of Changes

Wired JSON-RPC 2.0 newline-delimited framing for the stdio MCP server. Framing only; dispatch/tool routing lives in gargantua-tr4w.

**New files**
- `Sources/GargantuaCore/Models/MCP/MCPJSONRPC.swift` — `MCPRequestID` (int/string/null), `MCPJSONAny` (pass-through JSON), `MCPRequest`, `MCPResponse`, `MCPResponseError`, `MCPErrorCode` constants. Strict `jsonrpc: "2.0"` validation. Custom Codable distinguishes absent-id (notification) from present-null id using `c.contains(.id)`. Same key-presence logic applies to `result`/`error`/`params` so `{"result": null}` decodes as success with `.null` (fix caught by Codex review).
- `Sources/GargantuaCore/Services/MCP/MCPStdioTransport.swift` — `MCPStdioTransport` with pluggable `MCPMessageSource`/`MCPMessageSink`. Synchronous `run()` loop; parse-errors salvage id via `JSONSerialization` so clients get correlatable responses; notifications never get a response; encode-failure emits a fallback internal-error so the client never waits forever; log messages truncated at 512 chars with control-char escaping to prevent stderr corruption from attacker payloads. `StandardInputMessageSource` / `StandardOutputMessageSink` wrap real stdio; `MCPMessageHandler` / `MCPTransportLog` typealiases are `@Sendable` for future concurrency wrapping.

**Modified**
- `Sources/GargantuaMCP/main.swift` — replaced the catalog-print stub with a real transport instance + default method-not-found handler. stderr gets the banner + log; stdout reserved for protocol traffic.

**Tests** (37 new, 461 → 498 passing)
- `Tests/GargantuaCoreTests/Models/MCP/MCPJSONRPCTests.swift` — id variants, notification vs null-id, version validation, success/failure round-trips, null-result response, params null preservation.
- `Tests/GargantuaCoreTests/Services/MCP/MCPStdioTransportTests.swift` — parse error (null id), invalid request (salvaged id), method-not-found, nil handler → internal error, notification suppression, blank lines skipped, multi-request ordering, EOF, single-line output, non-finite encode fallback, control-char escape + truncation.

**Review**
- SC cascading. Sonnet self-review: acceptable defers for fractional-id salvage and line-length bound.
- Codex pass found the `result: null` decode bug (ERROR) and three WARN-level hardening items — all fixed in-branch before merge.

**Notes for next task (gargantua-tr4w)**
- Replace the default method-not-found handler with a dispatcher keyed by `MCPToolName` plus the MCP protocol methods (`initialize`, `tools/list`, `tools/call`).
- `MCPMessageHandler` is `@Sendable` so the dispatcher can be wrapped in an actor if state is needed.
- `MCPRequest.params` is `MCPJSONAny?`; the dispatcher will need to re-encode the param payload and decode it into the specific `MCPScanInput` / `MCPExplainInput` / etc. structs from `MCPToolSchemas.swift`. Round-trip through `JSONEncoder` → `JSONDecoder` is the simplest path since `MCPJSONAny` is Codable.
- Transport guarantees: notifications never see an emitted response; all non-notification requests receive either the handler response or an internal-error fallback; the client never hangs.
