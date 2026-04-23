---
# gargantua-uxdr
title: 'Task: MCP clean user notification, integration test, docs'
status: completed
type: task
priority: high
created_at: 2026-04-23T21:10:10Z
updated_at: 2026-04-23T22:53:02Z
parent: gargantua-u9il
blocked_by:
    - gargantua-afft
---

Fourth and final child of `gargantua-u9il`. Closes out the feature with the user-facing guardrail from PRD §7.4 (macOS notification with cancel), end-to-end validation via the real stdio transport, and documentation.

## Dependencies

Blocked by Task 3 (needs the fully-wired handler with audit + rate limit to validate end-to-end).

## Scope

- User notification service: on every MCP-initiated clean, post a `UNUserNotification` with a Cancel action and a short grace period before the `CleanupEngine.clean` call proceeds
- Integration test: spin up the Phase 3 MCP server over a pipe-backed stdio transport, run scan → clean, assert the audit trail, rate limiter, and cleanup results
- Docs: README + CONTRIBUTING pages describing Phase 3 MCP tool surface, client ID expectations, and safety posture

## Todo

- [x] Build `MCPCleanNotificationService` (or similar) that posts a `UNUserNotification` with title/body describing the incoming clean request and a `Cancel` action
- [x] Define a grace period (default 5s) during which the handler awaits the user's decision before invoking `CleanupEngine`
- [x] Cancel path: cancellation short-circuits the operation; audit entry records the cancel outcome; `MCPCleanOutput.per_item` reflects "skipped: user cancelled"
- [x] Unit tests with a fake notification service: timer elapses → proceed; cancel action → short-circuit
- [x] Integration test: end-to-end over pipe-backed stdio, `scan` → `clean` happy path, asserts audit entry + cleaned files. Use a temp home dir and an in-memory fake `CleanupEngine` so the test doesn't touch real filesystem
- [x] Integration test: protected-hard-reject surfaces correctly through stdio
- [x] Integration test: rate limiter triggers on second call
- [x] README update: list Phase 3 MCP tools (`clean`), explain the opt-in/entry point, and describe client ID requirements
- [x] CONTRIBUTING update: note Phase 2 (read-only) vs Phase 3 (destructive) split and the MCPPhase3Tools registry convention
- [x] Close `gargantua-u9il` feature bean once this task merges

## Non-goals

- SSE transport / bearer auth (separate bean: `gargantua-vdeg`)
- Dashboard MCP server status widget (separate bean: `gargantua-n4jn`)

## Summary of Changes

Fourth and final child of `gargantua-u9il`. Closes out the feature with the PRD §7.4 user-facing guardrail, end-to-end validation via pipe-backed stdio, and documentation.

**Files added:**
- `Sources/GargantuaCore/Services/MCP/MCPCleanNotificationService.swift` — protocol + `UNCleanNotificationService` (production, `UNUserNotificationCenter` with Cancel action + 5s grace + 150ms delegate-race buffer) + `NoopMCPCleanNotificationService` fallback + `MCPCleanNotificationFactory.automatic` picker.
- `Tests/GargantuaCoreTests/Services/MCP/MCPCleanNotificationServiceTests.swift` — 13 tests: Noop non-blocking, body shape, sanitization (newlines/controls/empty/oversize/quote-wrapping/injection resistance), factory stability, recording fake.
- `Tests/GargantuaCoreTests/Services/MCP/MCPStdioPhase3IntegrationHarness.swift` — pipe-backed `Phase3StdioTestServer` owning real dispatcher + real handlers + real rate limiter + fake scanner/cleaner/notification, plus `Phase3LineReader` timeout reader.
- `Tests/GargantuaCoreTests/Services/MCP/MCPStdioPhase3IntegrationTests.swift` — 6 end-to-end tests: happy path (audit attribution via dispatcher-captured name), protected hard-reject (no audit/cleaner/notification), rate-limit inside window (no second audit), user cancel (audit with 0 bytes), dry-run bypass (no rate/notification/audit), pre-init clean routes to `unknown` sentinel.

**Files modified:**
- `Sources/GargantuaMCP/main.swift` — transport moved off main thread onto a `DispatchQueue`; main calls `dispatchMain()` so `runBlocking` in the clean path cannot deadlock against `CleanupEngine.clean`'s `@MainActor`. Phase 3 wiring: shared `MCPScanSessionCache` between scan and clean; `MCPRateLimiter`; `AuditWriter`; `MCPCleanNotificationFactory.automatic`; cleaner closure that posts notification → proceed/cancel → `CleanupEngine.clean` or all-failed result; `exit(0)` on EOF for clean shutdown.
- `README.md` — Phase 3 MCP tools section: Phase 2 vs Phase 3 split, Phase 3 guardrails (protected hard-reject, rate limit, audit trail, user notification), client ID plumbing, permission caveat.
- `CONTRIBUTING.md` — MCP server contribution guide: file layout, `MCPPhase2Tools` vs `MCPPhase3Tools` registry split (never merge inside Core), pattern for new destructive tools, integration test pattern.

**Key decisions:**
- **Transport off-main, not CleanupEngine refactor**: Moving `transport.run()` to a background queue is surgical (one-file change) vs. rewriting the four `@MainActor` methods in `CleanupEngine`. The detached Task inside `runBlocking` can now freely hop to MainActor for `NSWorkspace.recycle` because main isn't parked.
- **Grace-period countdown after `add()` confirmation**: We wait up to 1s for the notification to be scheduled before starting the 5s grace, so slow post doesn't shorten the user's real reaction window.
- **150ms delegate-race buffer**: After the main grace timer elapses, we take one extra brief wait on the semaphore to catch Cancel callbacks in flight. The delegate sets `cancelled` under lock *before* signaling, so any observed signal guarantees a cancel — the buffer shrinks the "tapped just before timeout but callback landed just after" race from unbounded to <150ms. (Codex finding.)
- **Client-name sanitization**: `clientInfo.name` is attacker-controlled. Before rendering it in the notification body, we strip control chars, collapse newlines to space, trim, clip to 64 chars with an ellipsis, and wrap in quotes. Prevents a malicious client from injecting fake banner copy designed to look like a trusted UI prompt. Empty becomes the `"unknown"` sentinel. (Codex finding.)
- **Cancel returns all-failed `CleanupResult`, not a throw**: Lets the handler's success-path `recordAudit` fire (fail-closed) with `bytesFreed: 0`. Forensic tooling sees the attempted op even though nothing touched disk.
- **Cancel consumes rate-limit budget; dry-run does not**: Rate-limit check is pre-cleaner. A spamming agent whose user always taps Cancel still gets rate-limited — the attempt, not the effect, is what the limiter governs. Dry-run is non-destructive by definition so it bypasses both rate limit and audit.
- **Grace period = 5s**: PRD §7.4 silent. Splits reaction time vs. agent-blocking.
- **Notification permission not requested via `requestAuthorization`**: Would trigger a modal dialog on first run. For an MCP CLI that is undesirable. If permission hasn't been granted, the post silently fails and the grace period elapses → `.proceed`. Rate limit + audit trail still apply; only the per-clean user-consent guardrail is skipped. Documented in README.
- **Integration test cleaner resolves client ID via `dispatcher.currentClientIdentity()?.name`, not a hardcoded placeholder**: Codex finding — the original harness masked whether `main.swift` routed the real dispatcher identity or a literal into the notification service. Fixed so a regression in wiring would fail a test.
- **Unbundled-process fallback via `Bundle.main.bundleIdentifier != nil`**: `UNUserNotificationCenter.current()` crashes on unbundled processes. Factory returns `NoopMCPCleanNotificationService` when the bundle ID is absent.

**Review:**
- **OC cascade**. Opus self-review found no ERRORs, noted duplicate client-ID resolution and missing `requestAuthorization` (both accepted). Codex found 1 ERROR (delegate-race consent bypass) + 2 WARNINGs (unsanitized client ID in body, test harness hardcoding "test-client" so the production identity seam wasn't covered). All addressed in `fix(mcp): address Codex review findings` commit.

**Deferred follow-ups:**
- Ambient lint debt on sibling test files (pre-existing, documented in `afft`'s handoff).
- `Phase3LineReader.readAvailable` spawns a blocking read per poll; abandons reads on timeout. Codex suggestion. Not hit in practice — test `shutdown()` closes the pipe and drains orphaned reads. No flakes observed.
- `requestAuthorization` not called — if user hasn't granted, notifications silently fail. Acceptable fallback per README; could be revisited if a bundled desktop app consumer wants prompts.
- Rate limiter state does not persist across process restarts — a spamming agent can reset its budget by restarting the server. Audit trail still captures every attempt. Out of scope for Task 4.

**Verification:** 965/965 tests pass (+18 from 947). Build clean. Lint clean on new files.

**Closes:** `gargantua-u9il` feature bean (this is its last child).
