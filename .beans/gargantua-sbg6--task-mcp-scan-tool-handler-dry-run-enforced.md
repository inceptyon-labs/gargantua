---
# gargantua-sbg6
title: 'Task: MCP scan tool handler (dry-run enforced)'
status: completed
type: task
priority: high
created_at: 2026-04-18T22:18:37Z
updated_at: 2026-04-19T01:17:06Z
parent: gargantua-2h06
blocked_by:
    - gargantua-xc7m
---

Implement scan tool handler wired to the real scan pipeline. Must enforce dry_run=true at the type boundary (MCPScanInput rejects false). No destructive side effects possible via MCP scan. Emit results shaped per MCPScanOutput. Reference: MCPToolSchemas.swift MCPScanInput/Output.

## Summary of Changes

Wired the MCP `scan` tool handler into the dispatcher from gargantua-tr4w. Phase 2 MCP clients can now call `scan` and receive a categorized result set shaped per PRD §7.3. No code path in the handler can execute a destructive scan — dry-run is enforced at the `MCPScanInput` decode boundary.

### Files

- `Sources/GargantuaCore/Services/MCP/MCPScanToolHandler.swift` (new) — the handler itself. Synchronous contract to match `MCPToolHandler`; injected `Scanner` + `ProfileResolver` for testability; optional stderr log hook.
- `Sources/GargantuaMCP/main.swift` — registers the handler. Bridges the async `NativeScanAdapter.scan()` into the sync `Scanner` via a detached Task + DispatchSemaphore (`runBlocking`).
- `Tests/GargantuaCoreTests/Services/MCP/MCPScanToolHandlerTests.swift` (new) — 25 tests.

### Key decisions

- **Dry-run boundary unchanged.** `MCPScanInput.init(from:)` already rejects `dry_run:false`; the handler doesn't re-check. The point is that the type system makes it impossible for the handler to see a non-dry-run call.
- **Tool-domain vs JSON-RPC errors.** Scanner failures return `.failure(...)` (isError:true), not JSON-RPC errors. JSON-RPC errors are reserved for protocol-level problems (unknown profile, malformed args, empty categories override).
- **Empty categories override is rejected** with invalidParams. `NativeScanAdapter` treats empty `profile.categories` as match-all; passing `categories: []` over the wire would silently become a full scan, which is a footgun.
- **`custom` profile rejected** with invalidParams. The schema still advertises it per PRD §7.3, but the Phase 2 CLI has no persisted custom-profile surface. Silent fallback to `.light` was caught in Codex Pass 2 as a surprising contract downgrade. Wire it up when persisted profiles land.
- **ISO-8601 dates.** `last_accessed` is encoded as an ISO-8601 string (e.g. `"2026-04-11T14:30:00Z"`), not the `JSONEncoder` default numeric reference-date seconds. Codex Pass 2 catch — would have shipped a wire shape a real MCP client couldn't parse as a timestamp.
- **Error sanitization.** Only `LocalizedError.errorDescription` values cross the MCP boundary. Plain `Error` reflections (which may carry paths via NSError userInfo) get replaced with a generic `"internal error"` message; raw detail goes to stderr via the handler's log hook. Codex Pass 2 catch.
- **Total reclaimable excludes protected.** Matches the PRD example (18.2 GB safe + 5.3 GB review = 23.5 GB total; protected items have a count but no bytes tallied).
- **Protected items appear in `items[]`.** The LLM consumer needs visibility into what's on the Mac to answer questions; they're marked `safety: "protected"` so the client knows they're not actionable.
- **Default profile is `.light`** when no profile requested. The MCP CLI is a separate process and has no access to the app's persisted active-profile state; `.light` is the safest default until that bridge lands.

### Review

- SC cascading. Pass 1 (Opus self-review) caught: scanner load failures should be `.failure(...)` not `MCPToolError.internalError`. Pass 2 (Codex) caught: numeric Date encoding, error-message leakage, silent `custom` downgrade. All fixed before merge.

### Test counts

527 baseline → 552 (25 new handler tests). `swift build -Xswiftc -warnings-as-errors` clean.

### Notes for next task (gargantua-2xod: analyze + status)

- The pattern to follow: struct-handler with injected dependencies, `toolHandler: MCPToolHandler` accessor, register from `main.swift`. See how `scanRunner` bridges async→sync in main.swift if those handlers also need to call async services.
- Reuse the ISO-8601 `encodeAsJSONAny` pattern. If it's duplicated again, promote to a shared helper in `MCPRequestDispatcher.swift` or a new `MCPEncoding.swift`.
- `SystemMetricCollector` is what `analyze` and `status` should wire through per the prior handoff.
- Error sanitization pattern: keep `LocalizedError` messages but never reflect a plain `Error`. Pass `stderrLog` into the handler's `log` parameter from `main.swift`.
- Tool-domain failures (metric source unavailable, sysctl fails) should return `.failure(...)`, not throw.
