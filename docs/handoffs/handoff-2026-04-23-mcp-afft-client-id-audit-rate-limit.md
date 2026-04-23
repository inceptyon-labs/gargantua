# Session Handoff: MCP client ID, audit wiring, rate limiter (afft)

Date: 2026-04-23
Bean completed: `gargantua-afft`
Parent feature: `gargantua-u9il` (MCP clean tool handler)
Grandparent epic: `gargantua-rght` (MCP Server v2 — Phase 3)

## What was done

Task 3 of the `u9il` decomposition. Wires Phase 3 infrastructure onto `MCPCleanToolHandler`:

- **Rate limiter** — new `MCPRateLimiter` (sliding window, per-(client, tool), injectable clock). Default 1 op / 60s per PRD §7.4. Reusable for future destructive tools.
- **Audit** — `AuditEntry` gains optional `transport` + `clientID`. `AuditWriter.recordMCP` helper audits every completed MCP clean (success or failure). `AuditRecorder` injected into handler; success-path audit write failure is **fail-closed** (surfaces `internalError` to client). Failure-path audit is best-effort.
- **Client identity plumbing** — `MCPRequestDispatcher` decodes `clientInfo` at `initialize`, captures into `currentClientIdentity()`. Handler reads via `ClientIDProvider` closure. Identity resets on every re-init; blank/whitespace names normalized to nil; unknown clients share the "unknown" sentinel bucket.
- **Dry-run bypass** — dry-runs skip both rate limiter and audit (non-destructive).
- **Tests** — 40 new tests split across 4 files to avoid the ambient test-file-length error threshold:
  - `MCPRateLimiterTests.swift` (12)
  - `MCPCleanToolHandlerAuditTests.swift` (10)
  - `MCPCleanToolHandlerRateLimitTests.swift` (4)
  - `MCPCleanToolHandlerIntegrationTests.swift` (3 end-to-end)
  - `MCPRequestDispatcherTests.swift` (+10 clientInfo)
- **OC review completed.** Opus found no ERRORs. Codex found 1 ERROR (audit silently fail-open) and 2 WARNINGs (sticky re-init identity, blank-name bypass); all three fixed.

## Files changed this session

- Added `Sources/GargantuaCore/Services/MCP/MCPRateLimiter.swift`
- Added `Tests/GargantuaCoreTests/Services/MCP/MCPRateLimiterTests.swift`
- Added `Tests/GargantuaCoreTests/Services/MCP/MCPCleanToolHandlerAuditTests.swift`
- Added `Tests/GargantuaCoreTests/Services/MCP/MCPCleanToolHandlerRateLimitTests.swift`
- Added `Tests/GargantuaCoreTests/Services/MCP/MCPCleanToolHandlerIntegrationTests.swift`
- Modified `Sources/GargantuaCore/Models/AuditEntry.swift` (+ transport, clientID)
- Modified `Sources/GargantuaCore/Models/SafetyLevel.swift` (+ `.mcp` ConfirmationTier)
- Modified `Sources/GargantuaCore/Persistence/PersistedModels.swift` (+ fields through SwiftData)
- Modified `Sources/GargantuaCore/Services/AuditWriter.swift` (+ `recordMCP`)
- Modified `Sources/GargantuaCore/Services/MCP/MCPCleanToolHandler.swift` (rate limit + audit + clientID injection; fail-closed success-path audit)
- Modified `Sources/GargantuaCore/Services/MCP/MCPRequestDispatcher.swift` (clientInfo capture, reset-on-reinit, name normalization)
- Modified `Sources/GargantuaCore/Views/ConfirmationModalView.swift` (defensive `.mcp:` case)
- Modified `Tests/GargantuaCoreTests/Services/MCP/MCPCleanToolHandlerTests.swift` (fixture updated for UUID AuditIDGenerator)
- Modified `Tests/GargantuaCoreTests/Services/MCP/MCPRequestDispatcherTests.swift` (+ identity tests)

Two commits merged to main via merge commit.

## Next steps (ordered)

1. **`gargantua-uxdr`** — Task 4: user notification with Cancel window + integration test via real stdio + docs + `main.swift` wiring. No longer blocked.
   - **Critical pre-work:** resolve the `@MainActor` deadlock landmine in `MCPCleanToolHandler.Cleaner` typealias before writing the production closure. `CleanupEngine.clean` is `@MainActor` and stdio transport runs on main thread; wrapping in `runBlocking` the scan-path way would deadlock. See typealias doc. Options: move transport off-main, or refactor `CleanupEngine.clean` to non-`@MainActor`.
   - Production wiring shape is documented in the `afft` bean's summary.
2. Ambient lint-debt cleanup bean — still deferred. Now affects `MCPCleanToolHandlerAuditTests.swift`, `MCPCleanToolHandlerTests.swift`, `MCPRequestDispatcherTests.swift`, `MCPScanToolHandlerTests.swift`. All are over `type_body_length` and most are over `file_length` warning thresholds.

## Files to load next session

For Task 4 (`gargantua-uxdr`):

- `.beans/gargantua-uxdr--*.md` — task scope + todos (covers: user notification sheet, cancel window, integration test via stdio, main.swift wiring)
- `Sources/GargantuaCore/Services/MCP/MCPCleanToolHandler.swift` — especially the `Cleaner` typealias (Task 4 writes the production closure; read the deadlock landmine doc first)
- `Sources/GargantuaMCP/main.swift` — current Phase 2 wiring; Task 4 adds Phase 3 dispatcher setup, audit+limiter wiring, and the clean handler registration
- `Sources/GargantuaCore/Services/CleanupEngine.swift` (if the @MainActor refactor happens there)
- `Tests/GargantuaCoreTests/Services/MCP/MCPCleanToolHandlerIntegrationTests.swift` — the dispatcher-level integration pattern Task 4's stdio test will extend

## What NOT to re-read

- `Gargantua-PRD-v5-FINAL.md` § 7.3 / § 7.4 — fully consumed into bean bodies
- Historical handoffs under `docs/handoffs/archive/` (this session's will move there after load)
- `MCPCleanToolHandlerAuditTests.swift`, `MCPRateLimiterTests.swift` — comprehensive coverage already, don't audit
- The audit/limit flow — landed and reviewed. Task 4 just plugs dependencies in at call site.

## Open questions / ASSUMED decisions

- OPEN: `@MainActor` deadlock resolution in `CleanupEngine.clean`. Task 4 must pick a path — still OPEN, same as prior handoffs flagged.
- OPEN: User notification UX — sheet vs banner vs menu-bar indicator? PRD §7.4 says "app shows a notification" without specifying form. Task 4 design call.
- OPEN: Cancel-window length — PRD §7.4 silent on timing. Likely 3-5s before the clean proceeds. Task 4 picks.
- ASSUMED: `MCPRateLimiter` bucket growth is acceptable for stdio (one client per process). SSE multi-client support (`gargantua-vdeg`) will need key eviction.
- ASSUMED: Integration test runs the real `GargantuaMCP` binary via subprocess. Task 4 will set up a test helper that writes JSON-RPC frames to stdin and reads stdout.
- ASSUMED: `ConfirmationTier.mcp` stays as a leaf enum case. If Task 4 adds an in-app confirm flow for MCP (e.g., user approves each clean), this might need a different representation.
