---
# gargantua-53q1
title: 'Task: MCPCleanToolHandler + scan-session cache + core safety'
status: todo
type: task
priority: high
created_at: 2026-04-23T21:09:46Z
updated_at: 2026-04-23T21:10:18Z
parent: gargantua-u9il
blocked_by:
    - gargantua-0c7z
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

- [ ] Build `MCPScanSessionCache` (or similar): stores the most recent scan's `[ScanResult]` keyed by `id`, with a reasonable lifetime (TTL or "last scan wins")
- [ ] Wire `MCPScanToolHandler` to write into the cache on successful scan
- [ ] Implement `MCPCleanToolHandler` with a `CleanupEngine`-shaped dependency
- [ ] Bridge the sync handler boundary to `@MainActor` `CleanupEngine.clean` via the existing `runBlocking` pattern
- [ ] Reject `item_ids` not present in the cache with a clear `invalidParams` error
- [ ] Hard-reject the entire request if any resolved item has `safety == .protected_`, regardless of other flags
- [ ] If any resolved item has `safety == .review`, require `confirm: true`; reject with `invalidParams` otherwise
- [ ] Implement dry-run branch that returns `MCPCleanOutput` describing the would-be-cleaned set without invoking `CleanupEngine`
- [ ] Register the handler via a new Phase 3 dispatcher entry point or opt-in flag (not in `MCPPhase2Tools` dispatcher)
- [ ] Unit tests: happy path, protected-hard-reject, review-without-confirm rejection, unknown-id rejection, dry-run returns plan, mixed-tier sets

## Non-goals

- Audit writing (Task 3)
- Client ID plumbing (Task 3)
- Rate limiter (Task 3)
- User notification / cancel (Task 4)
- Integration test via real stdio transport (Task 4)
