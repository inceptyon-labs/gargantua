# Session Handoff: MCP analyze + status tool handlers

Date: 2026-04-18
Task completed: gargantua-2xod — "Task: MCP analyze + status tool handlers"
Parent: gargantua-2h06 (Feature: MCP Server v1) → gargantua-qe4a (Epic: Phase 2 Intelligence)

## What Was Done

Wired the `analyze` and `status` MCP tool handlers so Phase 2 clients can call both end-to-end. Three of five Phase 2 tools are now live (`scan`, `analyze`, `status`); two remain (`explain`, `list_profiles` — child Task `gargantua-o4ef`).

- Promoted `encodeAsJSONAny` + error-sanitiser helpers out of the scan handler into a new `MCPEncoding.swift` (per the prior session's handoff note: "if this helper gets copy-pasted a second time, promote it"). `MCPScanToolHandler` now calls the shared helpers; its private copies deleted.
- `MCPAnalyzeToolHandler`: injected `MetricsProvider`, shapes `SystemMetrics` + formatted disk usage into `MCPAnalyzeOutput`. `top_consumers` intentionally returns `[]` for now (scan-backed source lands with a follow-up). `recommendations` derived from threshold rules: disk ≥ 85%, memory pressure ≥ 85%, thermal ≥ `.serious`.
- `MCPStatusToolHandler`: injected `SnapshotProvider` that returns a new `SystemStatusSnapshot { metrics, uptime, coreCount }` so tests supply deterministic values instead of depending on real `ProcessInfo`. Percent fields = 0–100 floats rounded to one decimal; uptime renders as `{d}d {h}h` / `{h}h {m}m` / `{m}m`.
- Root-caused a latent `SystemMetrics.healthScore` trap (`Int(_.rounded())` on `NaN` / `±infinity`) by guarding `SystemMetrics.init` fractions via `isFinite` check. The live collector never produces non-finite values, but the handler's injected-provider surface is public and a misbehaving source must not be able to crash the MCP server. Same guard + `Double(Int.max).nextDown` saturation added in `formatUptime`.
- Wired both handlers in `Sources/GargantuaMCP/main.swift` via a shared `SystemMetricCollector()` and the existing `runBlocking` async→sync bridge.

Baseline 552 → 594 tests (all passing). `swift build -Xswiftc -warnings-as-errors` clean. SC review: Opus self-review Pass 1 clean; Codex Pass 2 flagged non-finite traps and two coverage gaps; all addressed in-branch before merge.

## Files Changed

- `Sources/GargantuaCore/Services/MCP/MCPEncoding.swift` (new)
- `Sources/GargantuaCore/Services/MCP/MCPAnalyzeToolHandler.swift` (new, ~125 lines)
- `Sources/GargantuaCore/Services/MCP/MCPStatusToolHandler.swift` (new, ~150 lines)
- `Sources/GargantuaCore/Services/MCP/MCPScanToolHandler.swift` (modified — shared helpers)
- `Sources/GargantuaCore/Models/SystemMetrics.swift` (modified — NaN/infinity guard)
- `Sources/GargantuaMCP/main.swift` (modified — analyze + status wiring)
- `Tests/GargantuaCoreTests/Services/MCP/MCPAnalyzeToolHandlerTests.swift` (new, 19 tests)
- `Tests/GargantuaCoreTests/Services/MCP/MCPStatusToolHandlerTests.swift` (new, 23 tests)

## Key Decisions (the ones that matter for next Tasks)

- **Shared `MCPEncoding` module.** All four remaining Phase 2 tool payloads go through `MCPEncoding.encodeAsJSONAny(_:)` (ISO-8601 dates) and `MCPEncoding.clientFacingMessage(for:)` (strip non-`LocalizedError` reflections). The latter is the single place that enforces "plain `Error` reflections never cross the MCP boundary"; new handlers must not bypass it.
- **Snapshot struct vs. two separate providers.** Status needs `SystemMetrics` + `uptime` + `coreCount`; bundled into `SystemStatusSnapshot` so the handler takes one injected closure, not three. Analyze's `MetricsProvider` stays a raw `SystemMetrics` closure since it needs nothing else.
- **`recommendations` are metric-based only, not scan-based.** Thresholds chosen so a healthy snapshot produces `[]`. The PRD §7.3 example includes scan-derived recommendations ("23 GB of dev artifacts older than 30 days") — those require scan context we don't have here. Will merge with scan-backed `top_consumers` in a follow-up Task on top of gargantua-2h06, outside the current four-child scope.
- **Non-finite Double hardening.** Root-caused in `SystemMetrics.init` (not just in handler defensive code) because `healthScore`'s trap would bite any caller, not just the MCP handlers. `formatUptime` caps at `Double(Int.max).nextDown` because `Double(Int.max)` rounds up past `Int.max` in IEEE 754 and would re-trap.
- **Byte formatting via `AlertItem.formatBytes`.** The PRD example shows `"14.2 GB"` but `formatBytes` drops the decimal for values ≥ 10 of a unit (`"14 GB"`). The app-canonical formatter is authoritative over the PRD example; test comment documents the divergence so future maintainers don't chase it.

## Next Steps (ordered)

Two remaining child Tasks under `gargantua-2h06`:

1. **gargantua-o4ef** — `explain` + `list_profiles` tool handlers. `MCPExplainInput` already enforces path-xor-item_id at decode. `MCPExplainOutput.lastAccessed` is a `Date?` and `MCPEncoding.encodeAsJSONAny` already applies the ISO-8601 strategy. For `list_profiles`, default `active` to `"light"` (same safest built-in the scan handler uses) until the persisted-profile bridge arrives.
2. **gargantua-2h06** itself closes once both remaining child Tasks are done.

## Files to Load Next Session

- `Sources/GargantuaCore/Services/MCP/MCPEncoding.swift` — shared helpers; reuse, don't duplicate.
- `Sources/GargantuaCore/Services/MCP/MCPAnalyzeToolHandler.swift` — canonical handler-struct pattern to clone for explain/list_profiles: injected `Sendable` provider typealias, `@Sendable` toolHandler accessor, MCPToolError rethrow + tool-domain `.failure(...)` for everything else.
- `Sources/GargantuaMCP/main.swift` — where `dispatcher.register(tool: .explain) { ... }` / `.listProfiles` calls will land. `runBlocking` helper still lives here if the data sources are async.
- `Sources/GargantuaCore/Models/MCP/MCPToolSchemas.swift` — `MCPExplainOutput`, `MCPListProfilesOutput`, `MCPProfileSummary` already defined.
- `Sources/GargantuaCore/Models/CleanupProfile.swift` (wherever built-ins `.light/.developer/.deep` live) — source of `list_profiles` data.

## What NOT to Re-Read

- `Sources/GargantuaCore/Services/MCP/MCPStdioTransport.swift` — framing is done.
- `Sources/GargantuaCore/Models/MCP/MCPJSONRPC.swift` — JSON-RPC types done.
- `Sources/GargantuaCore/Models/MCP/MCPToolDescriptor.swift` — registry done.
- `Sources/GargantuaCore/Services/MCP/MCPRequestDispatcher.swift` — dispatcher done; no changes needed to add the remaining two tools.
- `Sources/GargantuaCore/Services/MCP/MCPScanToolHandler.swift` — already migrated to shared helpers; read `MCPAnalyzeToolHandler.swift` instead as the canonical pattern (simpler: no profile resolver or categories override to distract).
- `Sources/GargantuaCore/Services/SystemMetricCollector.swift` — already wired; no touching unless the explain/list_profiles tasks grow disk-scan needs (they shouldn't).
- `Gargantua-PRD-v5-FINAL.md` §7.3 — already encoded in `MCP*Output` types.

## Reference

- PRD §7.3 (tool shapes) and §7.4 (safety guardrails).
- Completed child-task summary: `.beans/gargantua-2xod--task-mcp-analyze-status-tool-handlers.md` → "Summary of Changes".
- SC review fix commit: `fix(mcp): address Codex review findings on analyze/status handlers` (Pass 2 findings).
