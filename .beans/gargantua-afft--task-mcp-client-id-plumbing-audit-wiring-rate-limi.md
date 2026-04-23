---
# gargantua-afft
title: 'Task: MCP client ID plumbing, audit wiring, rate limiter'
status: completed
type: task
priority: high
created_at: 2026-04-23T21:09:58Z
updated_at: 2026-04-23T22:23:25Z
parent: gargantua-u9il
blocked_by:
    - gargantua-53q1
---

Third child of `gargantua-u9il`. Wires the Phase 3 infrastructure requirements from PRD §7.4: client identification end-to-end, audit entries for MCP-initiated operations, and rate limiting shared across future destructive Phase 3 tools.

## Dependencies

Blocked by Task 2 (needs a working handler to attach this infra to).

## Scope

- Client identifier plumbing: transport → dispatcher → handler → audit
- AuditWriter integration with `transport: "mcp"` + `client_id` fields
- Rate limiter enforcing max 1 clean per 60s per client identifier
- Designed so the rate limiter is reusable for any future Phase 3 destructive tool

## Todo

- [x] Extend `MCPRequestDispatcher` (or the transport layer) to surface a client identifier per request — source depends on transport (stdio initialize handshake metadata for now; SSE bearer-token subject later under `gargantua-vdeg`)
- [x] Pass the client identifier through to tool handlers via the existing handler context or a new parameter
- [x] Extend `AuditEntry` (or provide an MCP-specific variant) with `transport: "mcp"` and `client_id: String`
- [x] Wire `MCPCleanToolHandler` to write an audit entry via `AuditWriter` on both success and failure paths; surface `audit_id` in `MCPCleanOutput`
- [x] Implement `MCPRateLimiter` (value type or actor) with per-client, per-tool sliding-window enforcement (1 op / 60s default, configurable)
- [x] Gate `MCPCleanToolHandler` behind the rate limiter; return `invalidParams` with a clear "cool-down active, retry in Ns" message when tripped
- [x] Unit tests: audit entry shape (transport/client_id present), audit_id round-trips to output, rate limiter allows first call + rejects second inside window, rate limiter scoped per-client (client A doesn't starve client B), rate limiter recovers after window

## Non-goals

- User-facing notification with Cancel (Task 4)
- Integration test via real stdio (Task 4)
- Bearer-token-derived client ID for SSE (lives under `gargantua-vdeg`)



## Summary of Changes

**Files added:**
- `Sources/GargantuaCore/Services/MCP/MCPRateLimiter.swift` — sliding-window rate limiter, per-(client, tool) scope, injectable clock. Default 1 op / 60s per PRD §7.4.
- `Tests/GargantuaCoreTests/Services/MCP/MCPRateLimiterTests.swift` — 12 tests (allow/reject, eviction, isolation, concurrency).
- `Tests/GargantuaCoreTests/Services/MCP/MCPCleanToolHandlerAuditTests.swift` — 10 tests (shape, uuid round-trip, fail-paths, no-audit paths, unknown sentinel, fail-closed on success, best-effort on failure).
- `Tests/GargantuaCoreTests/Services/MCP/MCPCleanToolHandlerRateLimitTests.swift` — 4 tests (reject-in-window, dry-run bypass, per-client isolation, no-audit on reject).
- `Tests/GargantuaCoreTests/Services/MCP/MCPCleanToolHandlerIntegrationTests.swift` — 3 end-to-end tests pinning the dispatcher→handler attribution seam.

**Files modified:**
- `Sources/GargantuaCore/Models/AuditEntry.swift` — added optional `transport: String?` and `clientID: String?` fields. Backward compatible.
- `Sources/GargantuaCore/Models/SafetyLevel.swift` — added `ConfirmationTier.mcp`.
- `Sources/GargantuaCore/Persistence/PersistedModels.swift` — propagated new fields through `PersistedAuditEntry`.
- `Sources/GargantuaCore/Services/AuditWriter.swift` — added `recordMCP(...)` helper.
- `Sources/GargantuaCore/Services/MCP/MCPCleanToolHandler.swift` — added `ClientIDProvider`, `AuditRecorder`, `MCPRateLimiter` injected dependencies. Changed `AuditIDGenerator` to return `UUID`. Rate-limit check before cleaner; audit fail-closed on success path; "unknown" sentinel for unattributed clients.
- `Sources/GargantuaCore/Services/MCP/MCPRequestDispatcher.swift` — added `MCPClientIdentity`; dispatcher captures `clientInfo` in `initialize`; identity resets on every re-init; blank/whitespace names normalized to nil.
- `Sources/GargantuaCore/Views/ConfirmationModalView.swift` — defensive `.mcp:` case.

**Key decisions:**
- **Audit fail-closed on success path**: AuditWriter failure after successful clean surfaces `internalError` to the client — operator learns immediately rather than accumulating silent unaudited ops. Failure-path audit is best-effort. (Codex found this; original design swallowed failures.)
- **Identity reset on every initialize**: Prevents a rogue client from inheriting prior attribution via omit/malform on re-init. (Codex.)
- **Blank name normalization**: Stops a misbehaving client from creating its own rate-limit shard via empty names. (Codex.)
- **Sliding window, not fixed bucket**: A fixed bucket would let a client submit at second 59 and 61 and pass.
- **Per-(client, tool) limiter**: Future destructive tools share one enforcement point.
- **`AuditIDGenerator` returns `UUID`, not `String`**: Breaking change to Task 2's typealias; one representation avoids parse/unparse steps.
- **Dry-run bypasses both audit and rate limit**: Non-destructive by definition.
- **`ClientIDProvider` closure over direct dispatcher reference**: Handler decoupled from dispatcher.
- **`.mcp` ConfirmationTier**: Distinct from UI tiers so audit readers see MCP-initiated cleans for what they are.
- **Unknown-client sentinel shared**: A client that omits `clientInfo` can't game per-client isolation.
- **Test file split**: New Task 3 coverage in 4 dedicated files (audit, rate-limit, integration, plus dispatcher extensions) to avoid crossing SwiftLint error thresholds.

**Review:**
- **OC cascade**: Opus self-review found no ERRORs. Codex review found 1 ERROR (audit fail-open) + 2 WARNINGs (sticky re-init, blank name). All addressed in `fix(mcp): address Codex review findings` commit.

**Deferred follow-ups:**
- Ambient lint debt on sibling test files (pre-existing, acknowledged in prior handoffs).
- Clean-time safety revalidation (Codex concern from Task 2 review).
- Bucket growth unboundedness in `MCPRateLimiter` — SSE transport (`gargantua-vdeg`) will need key eviction.
- `@MainActor` deadlock landmine in `Cleaner` typealias — Task 4 must resolve before wiring `main.swift`.

**Verification:** 947/947 tests pass (+40 from 907). Build clean. Lint at baseline (no new errors).

**Notes for Task 4 (`gargantua-uxdr`):**
- Production wiring pattern: `auditRecorder: { try auditWriter.write($0) }`, `rateLimiter: MCPRateLimiter()`, `clientIDProvider: { dispatcher.currentClientIdentity()?.name }`.
- User notification can surface `audit_id` as the reference since audit is now persisted pre-response.
- Integration test via real stdio transport is Task 4's deliverable.
