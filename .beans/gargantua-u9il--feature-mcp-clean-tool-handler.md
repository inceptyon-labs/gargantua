---
# gargantua-u9il
title: 'Feature: MCP clean tool handler'
status: todo
type: feature
priority: high
created_at: 2026-04-23T20:54:06Z
updated_at: 2026-04-23T21:06:12Z
parent: gargantua-rght
---

Add the `clean` tool to the MCP server so agents can execute cleanup, not just scan/analyze. **Phase 3** feature from PRD §7.3 + §7.4 + §10 (v2 roadmap). Child of `gargantua-rght` (MCP Server v2 epic).

## Context

PRD §10 line 898 scopes the clean tool to Phase 3 alongside full agent integration. `MCPToolDescriptor.swift:151` documents the intentional split: Phase 2 tools are read-only/dry-run, and destructive capabilities live in a distinct Phase 3 registry so Phase 2 paths can't accidentally advertise them.

This is the core of the MCP v2 epic. Tier 3 agent integration (`gargantua-5e10`) depends on it.

## Tool contract (PRD §7.3)

- Tool name: `clean`, registered in a new `MCPPhase3Tools` registry — NOT in `MCPPhase2Tools.all`
- Input: `item_ids: [String]`, `method: "trash" | "delete"` (default `trash`), `confirm: true` (must be literal true)
- Returns: `{ cleaned: Int, freed: String, method: String, audit_id: String, per_item: [...] }`
- Dry-run mode (`dry_run: true`) returns the plan without touching the filesystem

## Safety guardrails (PRD §7.4)

- **Protected items:** hard reject server-side based on YAML classification. AI cannot lower the floor.
- **Review items:** require `confirm: true` in the call. Reject with `invalidParams` otherwise.
- **Rate limit:** max 1 clean operation per 60 seconds per client identifier.
- **User notification:** macOS notification on every MCP-initiated clean with a Cancel action (time-bounded grace, e.g. 5s) before the operation begins.
- **Audit trail:** log entry includes `transport: "mcp"` and `client_id: <identifier>`.
- **Item IDs must come from a prior scan** — resolve through a scan-session cache; reject unknown IDs.

## Architectural split

Clean tool lives in `MCPPhase3Tools` (new type) and is registered only in Phase 3 code paths. The existing Phase 2 server entry point stays read-only; a Phase 3 entry point (or a feature flag) opts into Phase 3 tools.

## Todo

- [ ] Add `MCPPhase3Tools.all` registry with the `clean` tool descriptor + schema
- [ ] Define `MCPCleanInput` / `MCPCleanOutput` models matching PRD §7.3
- [ ] Implement `MCPCleanToolHandler` that delegates to `CleanupEngine.clean(_:method:)`
- [ ] Bridge sync handler to `@MainActor` `CleanupEngine` via existing `runBlocking` pattern
- [ ] Scan-session cache: store most-recent scan results indexed by ID so `item_ids` resolve to `ScanResult` objects
- [ ] Reject `protected` items server-side regardless of request
- [ ] Enforce `confirm: true` for any `review`-tier item in the set
- [ ] Rate limiter (1 clean per 60s per client) — shared with any future Phase 3 destructive tool
- [ ] MCP client identifier plumbing: transport → dispatcher → handler → audit
- [ ] User-facing `UserNotification` with Cancel action and grace period before executing
- [ ] Audit log entry via existing `AuditWriter` with `transport: "mcp"` + `client_id`
- [ ] Dry-run mode returning the cleanup plan without filesystem changes
- [ ] Phase 3 entry point or opt-in flag for `MCPPhase3Tools` registration
- [ ] Unit tests: happy path, protected-hard-reject, review-without-confirm, unknown ID, rate-limit, dry-run, client ID in audit
- [ ] Integration test: stdio transport end-to-end with a fake cleanup engine
- [ ] Docs: update MCP tool list / README with Phase 3 advisory
