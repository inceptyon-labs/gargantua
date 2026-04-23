# Session Handoff: MCP clean — user notification, integration test, docs (uxdr)

Date: 2026-04-23
Bean completed: `gargantua-uxdr`
Feature completed: `gargantua-u9il` (MCP clean tool handler)
Grandparent epic: `gargantua-rght` (MCP Server v2 — Phase 3) — still open; one sibling feature (`gargantua-vdeg`) remains

## What was done

Task 4 — final task of the `u9il` decomposition. Closes out the PRD §7.4 user-consent guardrail, end-to-end integration coverage, and docs.

- **Notification service** — new `MCPCleanNotificationService` protocol + `UNCleanNotificationService` (production, `UNUserNotificationCenter` with Cancel action + 5s grace + 150ms delegate-race buffer) + `NoopMCPCleanNotificationService` fallback + `MCPCleanNotificationFactory.automatic` picker.
- **Production wiring in `main.swift`** — transport moved off main thread onto a background `DispatchQueue`; main calls `dispatchMain()`. Resolves the `@MainActor` deadlock landmine documented in Task 3's handoff: `CleanupEngine.clean` is `@MainActor`, so `runBlocking` from the transport thread would park main and deadlock the detached Task's hop back to MainActor. Moving the transport off-main was the chosen resolution (over refactoring `CleanupEngine.clean` to non-`@MainActor`).
- **Cleaner closure** — posts notification first; `.cancelled` returns a `CleanupResult` with every item `succeeded: false` (audit fires fail-closed with `bytesFreed: 0`); `.proceed` delegates to `CleanupEngine.clean` via `runBlocking`.
- **Pipe-backed stdio integration test** — `Phase3StdioTestServer` spins up a real dispatcher + real handlers + real rate limiter over OS pipes; fakes stop at scanner and cleaner. 6 end-to-end tests: happy path (audit attribution via dispatcher-captured name), protected hard-reject (no audit/cleaner/notification), rate-limit inside window, user cancel short-circuit, dry-run bypass, pre-init clean → `unknown` sentinel.
- **Docs** — README adds Phase 3 MCP tool section with guardrails + permission caveat; CONTRIBUTING adds MCP contribution guide with the `MCPPhase2Tools` vs `MCPPhase3Tools` registry split (never merge inside Core).
- **OC review cascade**. Opus self-review found no ERRORs. Codex found 1 ERROR (consent-bypass race between 5s timeout and delegate callback), 2 WARNINGs (attacker-controlled client name rendered verbatim in notification; test harness hardcoded `"test-client"` so the production attribution seam wasn't covered). All three fixed in `fix(mcp): address Codex review findings on uxdr` commit.

Four commits merged to main: handoff archive + feat + fix + bean closure.

## Files changed this session

- Added `Sources/GargantuaCore/Services/MCP/MCPCleanNotificationService.swift`
- Added `Tests/GargantuaCoreTests/Services/MCP/MCPCleanNotificationServiceTests.swift`
- Added `Tests/GargantuaCoreTests/Services/MCP/MCPStdioPhase3IntegrationHarness.swift`
- Added `Tests/GargantuaCoreTests/Services/MCP/MCPStdioPhase3IntegrationTests.swift`
- Modified `Sources/GargantuaMCP/main.swift` — transport off-main, Phase 3 wiring, `dispatchMain()`, `exit(0)` on EOF
- Modified `README.md` — Phase 3 MCP section
- Modified `CONTRIBUTING.md` — MCP contribution guide

## Next steps (ordered)

1. **`gargantua-vdeg`** — Feature: SSE transport + bearer auth. The only remaining feature under the `rght` epic.
   - Key design notes already captured in the feature's bean body.
   - `MCPRateLimiter` will need key eviction once multi-client SSE is live (unbounded growth acceptable for single-client stdio).
   - Bearer-token subject becomes the `clientID` instead of `clientInfo.name`.
   - The pattern `Phase3StdioTestServer` established is worth mirroring for SSE (pipe-backed integration harness).
2. Ambient lint-debt cleanup bean — still deferred. Affects `MCPCleanToolHandlerAuditTests.swift`, `MCPCleanToolHandlerTests.swift`, `MCPRequestDispatcherTests.swift`, `MCPScanToolHandlerTests.swift`. All are over `type_body_length` and most over `file_length` warning thresholds.
3. Optional follow-up: consider whether a bundled desktop-app consumer (not the standalone CLI) should call `UNUserNotificationCenter.requestAuthorization()` at first launch. Current wiring skips it; notifications silently fail when permission is not granted. See README note.

## Files to load next session

For `gargantua-vdeg`:

- `.beans/gargantua-vdeg--*.md` — feature scope + todos (SSE transport, bearer auth, multi-client)
- `Sources/GargantuaCore/Services/MCP/MCPStdioTransport.swift` — the transport pattern to mirror for SSE
- `Sources/GargantuaCore/Services/MCP/MCPRequestDispatcher.swift` — how `clientInfo` is captured today; SSE will swap to bearer subject
- `Sources/GargantuaCore/Services/MCP/MCPRateLimiter.swift` — bucket growth needs eviction for multi-client
- `Sources/GargantuaMCP/main.swift` — the Phase 3 wiring now lives here; SSE will need a parallel entry point or a shared composition root
- `Tests/GargantuaCoreTests/Services/MCP/MCPStdioPhase3IntegrationHarness.swift` — pipe-backed test pattern to mirror for SSE

## What NOT to re-read

- `Gargantua-PRD-v5-FINAL.md` § 7.3 / § 7.4 — fully consumed into bean bodies for this feature
- Historical handoffs under `docs/handoffs/archive/`
- `MCPCleanNotificationServiceTests.swift`, `MCPStdioPhase3IntegrationTests.swift` — comprehensive coverage, don't audit
- The clean-tool flow end-to-end — landed and reviewed. `vdeg`'s job is the transport; the handler is done.

## Open questions / ASSUMED decisions

- ASSUMED: 5s grace + 150ms delegate-race buffer — PRD silent; can be tuned if field telemetry shows it's too short or too long.
- ASSUMED: Notification permission not requested at startup — acceptable because fallback is `.proceed` (clean still subject to rate limit + audit). Could revisit for bundled app deployment.
- ASSUMED: `transport.run()` off-main + `dispatchMain()` as the deadlock fix. Alternative was refactoring `CleanupEngine.clean` to non-`@MainActor`; chose the smaller-blast-radius change.
- OPEN: Does the SSE transport (`vdeg`) need its own notification service wiring, or does the stdio service suffice as a shared component? The current service is transport-agnostic but the `automatic` factory may need revisiting for a long-running server (notification center delegate handling across many concurrent requests).
- OPEN: Rate limiter persistence across process restarts. Audit trail captures every attempt, so forensically it's not a gap, but a spamming agent can reset its budget by killing the server. Out of scope for `u9il`; revisit under `vdeg` or its own bean.

## Verification

- 965/965 tests pass (+18 from baseline 947).
- Build clean, no warnings.
- Lint clean on all new files.
- Merged to `main` via fast-forward.
- Final commit: `2b87e0a chore: close uxdr task and u9il feature beans`.
