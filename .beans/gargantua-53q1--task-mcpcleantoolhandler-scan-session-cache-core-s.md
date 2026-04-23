---
# gargantua-53q1
title: 'Task: MCPCleanToolHandler + scan-session cache + core safety'
status: in-progress
type: task
priority: high
created_at: 2026-04-23T21:09:46Z
updated_at: 2026-04-23T21:44:01Z
parent: gargantua-u9il
---

Second child of `gargantua-u9il`. Implements the clean tool handler with scan-session ID resolution and the core safety guardrails from PRD §7.4 (minus rate limit, audit plumbing, user notification — those land in Tasks 3 & 4).

## Dependencies

Blocked by Task 1 (needs `MCPCleanInput`/`Output` + `MCPPhase3Tools`).

## Scope

- Scan-session cache: map `item_id → ScanResult` so `item_ids` passed to `clean` resolve to real items from a prior scan
- Handler logic delegating to `CleanupEngine.clean(_:method:)`
- Server-side enforcement of protected-hard-reject and review-needs-confirm
- Dry-run mode
- Unknown ID rejection

## Todo

- [x] Build `MCPScanSessionCache` (or similar): stores the most recent scan's `[ScanResult]` keyed by `id`, with a reasonable lifetime (TTL or "last scan wins")
- [x] Wire `MCPScanToolHandler` to write into the cache on successful scan
- [x] Implement `MCPCleanToolHandler` with a `CleanupEngine`-shaped dependency
- [x] Bridge the sync handler boundary to `@MainActor` `CleanupEngine.clean` via the existing `runBlocking` pattern _(partial: sync `Cleaner` typealias + contract established; actual `runBlocking` wiring deferred to Task 4 because the scan pattern deadlocks with `@MainActor` — see handler doc)_
- [x] Reject `item_ids` not present in the cache with a clear `invalidParams` error
- [x] Hard-reject the entire request if any resolved item has `safety == .protected_`, regardless of other flags
- [x] If any resolved item has `safety == .review`, require `confirm: true`; reject with `invalidParams` otherwise _(satisfied by schema — `MCPCleanInput` requires `confirm: true` unconditionally, stricter than review-only)_
- [x] Implement dry-run branch that returns `MCPCleanOutput` describing the would-be-cleaned set without invoking `CleanupEngine`
- [x] Register the handler via a new Phase 3 dispatcher entry point or opt-in flag (not in `MCPPhase2Tools` dispatcher) _(handler exposes `toolHandler` and dispatcher tests prove Phase 2 hides `clean` while Phase 2+3 dispatcher advertises it; `main.swift` wiring is Task 4)_
- [x] Unit tests: happy path, protected-hard-reject, review-without-confirm rejection, unknown-id rejection, dry-run returns plan, mixed-tier sets

## Non-goals

- Audit writing (Task 3)
- Client ID plumbing (Task 3)
- Rate limiter (Task 3)
- User notification / cancel (Task 4)
- Integration test via real stdio transport (Task 4)


## Summary of Changes

**Files added:**
- `Sources/GargantuaCore/Services/MCP/MCPScanSessionCache.swift` — lock-guarded last-scan-wins cache mapping `ScanResult.id → ScanResult`
- `Sources/GargantuaCore/Services/MCP/MCPCleanToolHandler.swift` — `clean` handler with `Cleaner` and `AuditIDGenerator` closure dependencies
- `Tests/GargantuaCoreTests/Services/MCP/MCPScanSessionCacheTests.swift` — 8 tests
- `Tests/GargantuaCoreTests/Services/MCP/MCPCleanToolHandlerTests.swift` — 26 tests

**Files modified:**
- `Sources/GargantuaCore/Services/MCP/MCPScanToolHandler.swift` — added optional `sessionCache: MCPScanSessionCache?` init parameter; populates cache after successful scan

**Key decisions:**
- **Cache shape:** `final class` with `NSLock`-guarded dict, matching the repo idiom (see `MCPRequestDispatcher.lock`). Sync API is required because `MCPToolHandler` is sync; actors would force `await` hops that don't fit the contract. Contention is nil in production (stdio transport is single-request-at-a-time), the lock defends against future parallelism.
- **Session isolation:** single shared cache across the process. This is safe in Phase 2 stdio (one client per server process by MCP convention). Task 3 will add per-client-ID sharding alongside the audit entry.
- **Duplicate-id rejection:** added after Opus review found `lookupAll` would return duplicates in `found` and the cleaner would operate on the same path twice. Now rejected with a clear `invalidParams` at the handler boundary.
- **Confirm enforcement is at the decoder, not the handler:** `MCPCleanInput`'s custom `init(from:)` rejects `confirm != true`. Since the schema requires it unconditionally, the "review needs confirm" guardrail from the bean is implicitly always-enforced. No belt-and-suspenders check in the handler — would be dead code.
- **Method validation is at the handler, not the schema:** `method` is a plain `String` in `MCPCleanInput`; the JSON Schema advertises the enum but doesn't enforce it. Handler maps `trash | delete` via `resolveMethod`; anything else (including `tool_native`, which `CleanupEngine` accepts) rejects as `invalidParams`.
- **Outcome vocabulary:** `moved | skipped | failed`. Task 2 only emits `moved` and `failed` — protected items are rejected upstream so nothing reaches the engine as "skipped". The `skipped` slot is reserved for Task 3's rate-limit partial-skips.
- **Dry-run UX:** presents the plan as if every item succeeded (`outcome: "moved"` for each, `bytes_freed` populated). No top-level `dry_run` flag in the output — the request already documents the mode. Summary text says `[dry-run] would clean …` so human-facing content blocks are unambiguous.
- **`Cleaner` typealias is sync:** matches `MCPToolHandler`'s shape. Codex review flagged that the obvious Task 4 wiring (`runBlocking { await engine.clean(...) }`) would deadlock because `CleanupEngine.clean` is `@MainActor` and the stdio transport runs on the main thread. Documented on the typealias itself so Task 4 picks the right off-main approach (either move the transport off-main or make the engine entry point non-`@MainActor`).
- **Scan-time safety is a snapshot:** handler does not revalidate `safety` at clean-time. Symlink redirect is mitigated (both `NSWorkspace.recycle` and `FileManager.removeItem` operate on the link, not its target), and `CleanupEngine` operates on the exact scanned path. Live revalidation (re-scan at clean-time) fits the Task 3 hardening pass alongside audit + rate limit.
- **`freed`/`bytes_freed` is scan-size, not actual-removed bytes:** documented in the handler; `CleanupEngine` doesn't currently track actual bytes, and `emptyTrashContainer` in particular operates on current Trash contents rather than scanned contents. Agents should treat `freed` as best-effort estimate.

**Dispatcher integration:**
- No change to `MCPRequestDispatcher` or `MCPPhase2Tools.all`. The regression test `MCPToolSchemasTests.noCleanToolInPhase2` still passes.
- A Phase 3 dispatcher is built by passing `MCPPhase2Tools.all + MCPPhase3Tools.all` as the `tools` parameter and registering the clean handler. Two new tests verify: Phase 2-only dispatcher hides `clean` from `tools/list`; Phase 2+3 dispatcher advertises it and routes `tools/call`.
- `GargantuaMCP/main.swift` is untouched — Phase 3 production wiring is Task 4.

**Notes for Task 3 (`gargantua-afft` — audit + rate limit + client ID):**
- `MCPCleanToolHandler.AuditIDGenerator` is already plumbed through as an injectable closure. Task 3 replaces the default UUID generator with one that writes the audit entry and returns its ID.
- `MCPScanSessionCache` will need per-client-ID sharding. Current single-map shape is fine for Phase 2 stdio (one client per process) but an SSE transport would need isolation.
- The duplicate-id + unknown-id + protected rejection error messages echo client-provided strings back verbatim. Low risk (stdio client already controls what it sends), but a downstream HTML renderer would need escaping. Worth flagging in the audit entry format so investigators can see exactly what the client submitted.
- Safety revalidation at clean-time (Codex ERROR 2) is deferred here; Task 3 is the natural home if we decide to implement it.

**Verification:** 907/907 tests pass. Build clean. Lint clean on all source files; test file matches the sibling `MCPScanToolHandlerTests` length pattern (ambient file_length/type_body_length warnings — both files have been flagged for a later cleanup bean).
