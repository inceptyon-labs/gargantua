# Session Handoff: MCP scan tool handler

Date: 2026-04-18
Task completed: gargantua-sbg6 — "Task: MCP scan tool handler (dry-run enforced)"
Parent: gargantua-2h06 (Feature: MCP Server v1) → gargantua-qe4a (Epic: Phase 2 Intelligence)

## What Was Done

Wired the first real MCP tool handler into the dispatcher that landed in gargantua-tr4w. Phase 2 MCP clients can now call `scan` end-to-end:

- Arguments decoded via `MCPScanInput` (dry-run enforced at the type boundary — `dry_run: false` is rejected at decode time; the handler has no code path that could execute a destructive scan).
- Profile resolved by name (`developer` / `light` / `deep` supported; `custom` rejected with invalidParams until persisted profiles land; unknown names → invalidParams).
- Optional `categories` override replaces the profile's categories on a rebuilt profile; empty array is rejected (would become match-all under NativeScanAdapter's filter).
- Scan runs via `NativeScanAdapter.loadDefaults(profile:)`; async is bridged to sync in `main.swift` via a detached Task + DispatchSemaphore (`runBlocking`).
- Results shaped into `MCPScanOutput` per PRD §7.3. `total_reclaimable` sums safe+review bytes; protected items appear in `items[]` with a count but no byte tally.
- Dates encoded as ISO-8601 strings on the wire (e.g. `"2026-04-11T14:30:00Z"`), not the JSONEncoder default numeric form.
- Scanner errors: `MCPToolError.invalidParams`/`internalError` rethrow to the dispatcher; anything else becomes a tool-domain `.failure(...)` with `isError: true`. Only `LocalizedError.errorDescription` messages cross the MCP boundary; plain `Error` reflections get replaced with `"internal error"` and the raw detail goes to stderr via the handler's log hook.

## Files Changed

- `Sources/GargantuaCore/Services/MCP/MCPScanToolHandler.swift` (new, ~200 lines)
- `Sources/GargantuaMCP/main.swift` (scan wiring + `runBlocking` async→sync bridge)
- `Tests/GargantuaCoreTests/Services/MCP/MCPScanToolHandlerTests.swift` (new, 25 tests)

Baseline 527 → 552 tests (all passing). `swift build -Xswiftc -warnings-as-errors` clean. SC review: Sonnet/Opus self-review Pass 1 caught the scanner-load error-mapping issue; Codex Pass 2 caught numeric date encoding, error-message leakage, and silent `custom` fallback. All three fixed in-branch before merge.

## Key Decisions (the ones that matter for next Tasks)

- **Handler shape.** `struct MCPScanToolHandler: Sendable` with injected `Scanner` (sync `@Sendable (CleanupProfile) throws -> [ScanResult]`), `ProfileResolver` (sync `@Sendable (String?) throws -> CleanupProfile`), and optional `log: MCPDispatcherLog?`. A `toolHandler: MCPToolHandler` accessor bridges to the dispatcher's registration contract. Registered with `dispatcher.register(tool: .scan, handler: scanHandler.toolHandler)`.
- **Sync handler, async backend.** `MCPToolHandler` is synchronous. When the real scan is async, bridge at the `main.swift` edge using the `runBlocking` helper (detached Task + `DispatchSemaphore` + lock-guarded `ResultHolder`). The transport loop processes one request at a time, so blocking the transport thread during a scan is fine; Task.detached runs on the cooperative pool so no deadlock.
- **Tool-domain vs JSON-RPC error policy reaffirmed.** Unknown profile / malformed params / empty categories → `MCPToolError.invalidParams` → -32602. Scanner throws `MCPToolError.invalidParams` / `.internalError` → rethrown as-is to the dispatcher. Scanner throws anything else → `.failure("Scan failed: <sanitized>")` with `isError: true`. Never leak raw error reflections to the client.
- **ISO-8601 on the MCP wire.** `encodeAsJSONAny` in the handler sets `dateEncodingStrategy = .iso8601` before encoding the Codable output. `MCPExplainOutput` also has `lastAccessed: Date?` and will need the same treatment. If this helper gets copy-pasted a second time, promote it to a shared module-level helper (e.g. `Sources/GargantuaCore/Services/MCP/MCPEncoding.swift`).
- **Default profile is `.light`.** The MCP CLI is a distinct process with no access to the app's persisted active profile. This will likely change when the persisted-profile bridge lands — that will also unlock the `custom` profile path.
- **Protected items appear in `items[]`.** LLM consumers need visibility; they're marked `safety: "protected"` so the client knows they aren't actionable.

## Next Steps (ordered)

Three remaining child Tasks under `gargantua-2h06`:

1. **gargantua-2xod** — `analyze` + `status` tool handlers. Wire through `SystemMetricCollector`. Output shapes already defined: `MCPAnalyzeOutput` (health_score, disk, top_consumers, recommendations), `MCPStatusOutput` (health_score, cpu, memory, disk, uptime). Apply the same error sanitization + optional log-hook pattern.
2. **gargantua-o4ef** — `explain` + `list_profiles` tool handlers. `MCPExplainInput` already enforces path-xor-item_id at decode. `MCPExplainOutput.lastAccessed` is also a `Date?` — will need the same ISO-8601 encoding strategy.
3. **gargantua-2h06** itself closes once all four child Tasks are done.

## Files to Load Next Session

- `Sources/GargantuaCore/Services/MCP/MCPScanToolHandler.swift` — canonical handler-struct pattern (injected deps, ISO-8601 encoder, error sanitization, log hook).
- `Sources/GargantuaMCP/main.swift` — where `dispatcher.register(tool: .analyze) { ... }` / `.status` / `.explain` / `.listProfiles` calls will land. Also has the `runBlocking` helper if the metric collectors are async.
- `Sources/GargantuaCore/Services/MCP/MCPRequestDispatcher.swift` — the `MCPToolHandler`/`MCPToolArguments`/`MCPToolCallResult` contract to target (no changes expected).
- `Sources/GargantuaCore/Models/MCP/MCPToolSchemas.swift` — `MCPAnalyzeOutput`, `MCPStatusOutput`, `MCPExplainOutput`, `MCPListProfilesOutput` already defined.
- `Sources/GargantuaCore/Services/SystemMetricCollector.swift` — source of truth for analyze/status data (read this when starting 2xod).

## What NOT to Re-Read

- `Sources/GargantuaCore/Services/MCP/MCPStdioTransport.swift` — framing is done, stable.
- `Sources/GargantuaCore/Models/MCP/MCPJSONRPC.swift` — JSON-RPC types are done.
- `Sources/GargantuaCore/Models/MCP/MCPToolDescriptor.swift` — registry/schema is done.
- `Tests/GargantuaCoreTests/Services/MCP/MCPRequestDispatcherTests.swift` — dispatcher coverage done.
- `Tests/GargantuaCoreTests/Services/MCP/MCPScanToolHandlerTests.swift` — scan handler coverage done; new tests for the next handlers go in their own files.
- `Gargantua-PRD-v5-FINAL.md` §7.3 — already consulted for output shapes; shapes are now encoded in the `MCP*Output` types.

## Reference

- PRD §7.3 (tool shapes) and §7.4 (safety guardrails — especially scan dry-run).
- Completed child-task summary: `.beans/gargantua-sbg6--task-mcp-scan-tool-handler-dry-run-enforced.md` → "Summary of Changes".
- SC review fix commits: `fix(mcp): scan load failures surface as tool-domain .failure` (Pass 1), `fix(mcp): address Codex review findings on scan handler` (Pass 2).
