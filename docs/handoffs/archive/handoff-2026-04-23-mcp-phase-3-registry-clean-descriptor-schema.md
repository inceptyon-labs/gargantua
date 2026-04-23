# Session Handoff: MCP Phase 3 registry + clean descriptor/schema

Date: 2026-04-23
Bean completed: `gargantua-0c7z`
Parent feature: `gargantua-u9il` (MCP clean tool handler)
Grandparent epic: `gargantua-rght` (MCP Server v2 — Phase 3)

## What was done

- Re-scoped `gargantua-u9il` from "Phase 2 gap" to Phase 3 (per PRD §10 line 898) and decomposed it into 4 sequential child tasks under a new epic `gargantua-rght` (MCP Server v2).
- Implemented Task 1 (`gargantua-0c7z`): Phase 3 tool registry + `clean` tool descriptor/schema.

## Files changed this session

- Added `Sources/GargantuaCore/Models/MCP/MCPCleanSchemas.swift`
- Added `Sources/GargantuaCore/Models/MCP/MCPPhase3Tools.swift`
- Added `Tests/GargantuaCoreTests/Models/MCP/MCPCleanSchemasTests.swift`
- Modified `Sources/GargantuaCore/Models/MCP/MCPToolDescriptor.swift` (added `.clean` case, updated docs)
- Modified `Tests/GargantuaCoreTests/Services/MCP/MCPRequestDispatcherTests.swift` (fixed Phase 2 assertion)
- Added/modified bean files under `.beans/` for `rght`, `u9il`, and the 4 child tasks
- Two UI refactor commits earlier in the session (unrelated to u9il): AI modal button style unification + dashboard recommendation-led redesign

## Next steps (ordered)

1. **`gargantua-53q1`** — Task 2: `MCPCleanToolHandler` + scan-session cache + core safety. Blocked-by `0c7z`, now unblocked.
2. **`gargantua-afft`** — Task 3: MCP client ID plumbing, audit wiring, rate limiter. Blocked by `53q1`.
3. **`gargantua-uxdr`** — Task 4: User notification + integration test + docs. Blocked by `afft`.
4. File an ambient-lint-debt follow-up bean if desired — `ScanBucketView.swift` type body length (my refactor pushed it over), plus longstanding violations in `ProcessRunner.swift`, `MCPRequestDispatcher.swift`, etc. Non-blocking for v2 MCP work.

## Files to load next session

For Task 2 (`gargantua-53q1`):
- `.beans/gargantua-53q1--*.md` — task scope + todos
- `.beans/gargantua-0c7z--*.md` — for the "Notes for Task 2" section at the bottom (mapping concerns, idiom conventions)
- `Sources/GargantuaMCP/main.swift` — for the `runBlocking` async-to-sync bridge pattern and handler registration idiom
- `Sources/GargantuaCore/Services/CleanupEngine.swift` — target API (`@MainActor clean(_:method:) async -> CleanupResult`); see the two-vs-three-state outcome mapping note
- `Sources/GargantuaCore/Services/MCP/MCPScanToolHandler.swift` — handler template to mirror
- `Sources/GargantuaCore/Models/MCP/MCPCleanSchemas.swift` + `MCPPhase3Tools.swift` — the types landed by `0c7z`

## What NOT to re-read

- `Gargantua-PRD-v5-FINAL.md` § 7.3 / § 7.4 / § 10 — already re-scoped into the bean bodies; rely on those
- The Phase 2 tool registry pattern — already surveyed (see `0c7z` summary for idioms)
- Historical handoffs under `docs/handoffs/archive/` — none relevant to Phase 3

## Open questions / ASSUMED decisions

- ASSUMED: Phase 3 entry point will be introduced in Task 2 (it could have been in Task 1 as scaffolding, but the bean decomposition placed it with the handler). Revisit if Task 2 feels too chunky.
- OPEN: How does client identity reach the dispatcher in stdio transport? PRD §7.2 mentions bearer-token-derived client IDs for SSE (Phase 3 transport, separate bean `gargantua-vdeg`) but is silent on stdio. Task 3 (`afft`) needs to decide: MCP `initialize` handshake metadata? Environment variable at launch? Deferred to Task 3's planning.
