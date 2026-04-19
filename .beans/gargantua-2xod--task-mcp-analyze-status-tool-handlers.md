---
# gargantua-2xod
title: 'Task: MCP analyze + status tool handlers'
status: completed
type: task
priority: high
created_at: 2026-04-18T22:18:41Z
updated_at: 2026-04-19T01:35:59Z
parent: gargantua-2h06
blocked_by:
    - gargantua-xc7m
---

Implement analyze handler populating MCPAnalyzeOutput from SystemMetricCollector + disk usage summary. Implement status handler from SystemMetrics (percent fields x100, bytes formatted). Reference: MCPToolSchemas.swift MCPAnalyzeOutput/MCPStatusOutput, SystemMetricCollector.swift.


## Summary of Changes

Wired the `analyze` and `status` MCP tool handlers on top of `SystemMetricCollector`, following the handler-per-tool pattern established by `MCPScanToolHandler` (gargantua-sbg6). Two MCP tools now go end-to-end; three of five Phase 2 tools are live.

**New files**
- `Sources/GargantuaCore/Services/MCP/MCPEncoding.swift` — shared `encodeAsJSONAny<T: Encodable>` (ISO-8601 date strategy) and `clientFacingMessage(for:)` error sanitiser, promoted out of the scan handler per the prior session's handoff note ("if this helper gets copy-pasted a second time, promote it").
- `Sources/GargantuaCore/Services/MCP/MCPAnalyzeToolHandler.swift` — `struct MCPAnalyzeToolHandler: Sendable` with injected `MetricsProvider`. Shapes `SystemMetrics` + formatted disk usage into `MCPAnalyzeOutput`. `top_consumers` intentionally empty for now (scan-backed source lands with a follow-up); `recommendations` derived from threshold rules on disk (>=85%), memory pressure (>=85%), and thermal (>= .serious).
- `Sources/GargantuaCore/Services/MCP/MCPStatusToolHandler.swift` — `struct MCPStatusToolHandler: Sendable` with injected `SnapshotProvider`. Introduces `SystemStatusSnapshot { metrics, uptime, coreCount }` so tests can feed deterministic values instead of depending on the host's real `ProcessInfo`. Percent fields are `0-100` floats rounded to one decimal; uptime formats as `{d}d {h}h` / `{h}h {m}m` / `{m}m`.
- Tests: `MCPAnalyzeToolHandlerTests` (19 tests) and `MCPStatusToolHandlerTests` (23 tests).

**Modified**
- `Sources/GargantuaCore/Services/MCP/MCPScanToolHandler.swift` — now calls the shared `MCPEncoding.*` helpers; deleted its private copies.
- `Sources/GargantuaMCP/main.swift` — registered both new tools via `dispatcher.register(tool: .analyze/.status, ...)`. Providers call `runBlocking { await SystemMetricCollector().collect() }` (same async→sync bridge the scan runner uses); status additionally reads `ProcessInfo.processInfo.systemUptime` / `activeProcessorCount` synchronously after the `collect()` returns.
- `Sources/GargantuaCore/Models/SystemMetrics.swift` — root-caused a latent `healthScore` trap by guarding the `init` fractions against `NaN` / `±infinity`. The live collector never produces non-finite values, but the injected-provider surface is public and a misbehaving source must not be able to crash the MCP server via `Int(_.rounded())`.

**Review (SC tier)**
- Pass 1 (Opus self-review): no ERRORs.
- Pass 2 (Codex): two WARNINGs (non-finite Double traps, `Int64(clamping:)` documented saturation) and coverage suggestions (exact-threshold test at 0.85, extra-argument tolerance). Both warnings addressed at root cause; all suggestions landed as tests before merge.

**Verification**
- `swift test`: 552 baseline → 594 passing (42 new).
- `swift build -Xswiftc -warnings-as-errors`: clean.
- `swiftlint`: clean for the new code (only pre-existing `type_body_length` / `file_length` warnings remain in unrelated ambient files, consistent with the existing scan-handler test file's shape).

**Notes for next Task (gargantua-o4ef — `explain` + `list_profiles`)**
- `MCPEncoding.swift` now exists. Use `MCPEncoding.encodeAsJSONAny(_:)` and `MCPEncoding.clientFacingMessage(for:)` directly; `MCPExplainOutput.lastAccessed` is a `Date?` so the ISO-8601 strategy already applies.
- `MCPExplainInput` enforces path-xor-item_id at decode, so the handler doesn't need a redundant guard.
- `list_profiles.active` defaults to the same safest built-in (`light`) the scan handler uses until the persisted-profile bridge lands.
- Follow the same injected-provider shape (`Sendable` struct + throwing `@Sendable` typealias + optional `log: MCPDispatcherLog?`) so the error-sanitisation / MCPToolError-rethrow pattern stays uniform across the four handlers.
