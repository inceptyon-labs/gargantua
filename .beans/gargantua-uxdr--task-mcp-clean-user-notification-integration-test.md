---
# gargantua-uxdr
title: 'Task: MCP clean user notification, integration test, docs'
status: todo
type: task
priority: high
created_at: 2026-04-23T21:10:10Z
updated_at: 2026-04-23T21:10:24Z
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

- [ ] Build `MCPCleanNotificationService` (or similar) that posts a `UNUserNotification` with title/body describing the incoming clean request and a `Cancel` action
- [ ] Define a grace period (default 5s) during which the handler awaits the user's decision before invoking `CleanupEngine`
- [ ] Cancel path: cancellation short-circuits the operation; audit entry records the cancel outcome; `MCPCleanOutput.per_item` reflects "skipped: user cancelled"
- [ ] Unit tests with a fake notification service: timer elapses → proceed; cancel action → short-circuit
- [ ] Integration test: end-to-end over pipe-backed stdio, `scan` → `clean` happy path, asserts audit entry + cleaned files. Use a temp home dir and an in-memory fake `CleanupEngine` so the test doesn't touch real filesystem
- [ ] Integration test: protected-hard-reject surfaces correctly through stdio
- [ ] Integration test: rate limiter triggers on second call
- [ ] README update: list Phase 3 MCP tools (`clean`), explain the opt-in/entry point, and describe client ID requirements
- [ ] CONTRIBUTING update: note Phase 2 (read-only) vs Phase 3 (destructive) split and the MCPPhase3Tools registry convention
- [ ] Close `gargantua-u9il` feature bean once this task merges

## Non-goals

- SSE transport / bearer auth (separate bean: `gargantua-vdeg`)
- Dashboard MCP server status widget (separate bean: `gargantua-n4jn`)
