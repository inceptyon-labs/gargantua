# Session Handoff: MCP clean handler + scan-session cache (53q1)

Date: 2026-04-23
Bean completed: `gargantua-53q1`
Parent feature: `gargantua-u9il` (MCP clean tool handler)
Grandparent epic: `gargantua-rght` (MCP Server v2 — Phase 3)

## What was done

Task 2 of the `u9il` decomposition:

- Added `MCPScanSessionCache` — lock-guarded last-scan-wins cache mapping `ScanResult.id → ScanResult`. Lives under `Sources/GargantuaCore/Services/MCP/`.
- Wired `MCPScanToolHandler` to populate the cache via new optional `sessionCache:` init parameter. Populated after successful scan only.
- Added `MCPCleanToolHandler` — Phase 3 `clean` tool handler with `Cleaner` (sync, throws) + `AuditIDGenerator` closure dependencies. Resolves `item_ids` against the cache, hard-rejects protected, rejects duplicates + unknowns + bad methods, dry-run returns plan without invoking cleaner, maps engine's 2-state outcomes to 3-state wire vocabulary (`moved | skipped | failed`).
- 33 new tests (8 cache + 25 handler, plus 1 duplicate-id test added post-Opus-review = 26 handler). Total suite: 907/907 pass.
- OC review completed. Opus flagged duplicate-id escape → fixed. Codex flagged 3 concerns; 2 are architecture concerns deferred to Task 3/4 (documented inline on the handler), 1 is a Task 4 wiring landmine (documented on the `Cleaner` typealias so the next author sees it).

## Files changed this session

- Added `Sources/GargantuaCore/Services/MCP/MCPScanSessionCache.swift`
- Added `Sources/GargantuaCore/Services/MCP/MCPCleanToolHandler.swift`
- Added `Tests/GargantuaCoreTests/Services/MCP/MCPScanSessionCacheTests.swift`
- Added `Tests/GargantuaCoreTests/Services/MCP/MCPCleanToolHandlerTests.swift`
- Modified `Sources/GargantuaCore/Services/MCP/MCPScanToolHandler.swift` (added `sessionCache:` init parameter + cache populate)
- Modified `.beans/gargantua-53q1--...md` (checked off todos, status completed, summary appended)
- Archived prior handoff under `docs/handoffs/archive/`

Four commits on main (merged via `d067c47`), plus the bean-status follow-up commit.

## Next steps (ordered)

1. **`gargantua-afft`** — Task 3: MCP client ID plumbing, audit wiring, rate limiter. No longer blocked.
2. **`gargantua-uxdr`** — Task 4: user notification + integration test + docs + main.swift wiring. Blocked by `afft`. NOTE: Task 4 is also where the `@MainActor` deadlock landmine needs to be resolved — see `MCPCleanToolHandler.Cleaner` typealias doc.
3. Ambient lint-debt follow-up bean (still deferred from the 0c7z handoff; `MCPCleanToolHandlerTests.swift` adds another file exceeding file_length/type_body_length limits, matching the `MCPScanToolHandlerTests.swift` precedent).

## Files to load next session

For Task 3 (`gargantua-afft`):

- `.beans/gargantua-afft--*.md` — task scope + todos (likely covers: client identity, audit entry shape, rate limiter, the wiring points through to `MCPCleanToolHandler`)
- `Sources/GargantuaCore/Services/MCP/MCPCleanToolHandler.swift` — especially the `AuditIDGenerator` typealias (Task 3 replaces the default UUID generator with one that writes a real audit entry) and the two documented concerns (TOCTOU safety snapshot, byte-counting)
- `Sources/GargantuaCore/Services/MCP/MCPScanSessionCache.swift` — sharding point for per-client isolation (single-map today; afft likely needs per-client-id keying)
- `Sources/GargantuaCore/Models/AuditEntry.swift` — existing audit model, bean 3 likely extends or wraps
- PRD §7.4 — the full destructive-path guardrail spec; rate limit numbers live there

## What NOT to re-read

- `Gargantua-PRD-v5-FINAL.md` § 7.3 — already consumed into the bean bodies for `rght` and its children
- Historical handoffs under `docs/handoffs/archive/` (including the one I just archived from this session)
- The Phase 2 tool registry pattern — `MCPCleanToolHandler` already mirrors the idioms; `MCPScanToolHandler` is the closest template but no need to re-audit

## Open questions / ASSUMED decisions

- ASSUMED: Task 3's `AuditIDGenerator` implementation will replace the default UUID generator — I've already plumbed it as an injectable closure so the call site can swap freely. No `MCPCleanToolHandler` change required.
- ASSUMED: Task 3 per-client-id cache sharding will either wrap `MCPScanSessionCache` or replace it. Current single-map cache is fine for Phase 2 stdio (one client per process) but SSE transport (`gargantua-vdeg`) needs isolation.
- OPEN: How does client identity reach the dispatcher in stdio transport? PRD §7.2 addresses SSE (Phase 3 transport, separate bean `gargantua-vdeg`) but is silent on stdio. Task 3 must decide: `initialize` handshake metadata? Env var at launch? Same question the prior handoff flagged; still open.
- OPEN: Does Task 3 re-validate `safety` at clean-time (Codex ERROR 2), or do we accept the snapshot semantics? Current handler docs say "belongs with Task 3 hardening" — revisit when starting afft.
- OPEN: Does Task 4 move `CleanupEngine.clean` off `@MainActor`, or move the transport off the main thread? The deadlock landmine needs a real resolution before `main.swift` wires the `Cleaner`. Flagged in the `Cleaner` typealias doc.
