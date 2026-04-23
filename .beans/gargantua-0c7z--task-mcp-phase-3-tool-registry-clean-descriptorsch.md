---
# gargantua-0c7z
title: 'Task: MCP Phase 3 tool registry + clean descriptor/schema'
status: completed
type: task
priority: high
created_at: 2026-04-23T21:09:36Z
updated_at: 2026-04-23T21:20:26Z
parent: gargantua-u9il
---

First child of `gargantua-u9il`. Establishes the Phase 3 MCP tool registry (distinct from Phase 2) and defines the `clean` tool's descriptor + input/output schemas per PRD §7.3.

## Scope

Foundation only — no handler logic, no cleanup execution. Just the types and registration points so later children have somewhere to plug in.

## Todo

- [x] Add `MCPPhase3Tools` enum/namespace parallel to `MCPPhase2Tools`, with `.all` collection
- [x] Define `clean` tool descriptor inside `MCPPhase3Tools`: name, description, input JSON schema per PRD §7.3
  - `item_ids: [string]` required
  - `method: "trash" | "delete"` optional, default trash
  - `confirm: boolean` required, must be literal true (use `const: .bool(true)`)
  - `dry_run: boolean` optional, default false
- [x] Add `MCPToolName.clean` case so the descriptor can reference it
- [x] Define `MCPCleanInput` Codable struct matching the schema (rejects `confirm != true` at decode)
- [x] Define `MCPCleanOutput` Codable struct: `cleaned: Int`, `freed: String`, `method: String`, `audit_id: String`, `per_item: [MCPCleanItemResult]`
- [x] Define `MCPCleanItemResult`: `id`, `outcome: "moved" | "skipped" | "failed"`, optional `reason`, optional `bytes_freed`
- [x] Unit tests for the schema: confirm const-true rejection, method enum validation, required fields, round-trip encode/decode
- [x] No dispatcher registration yet — that happens in Task 2 when the handler exists

## Non-goals

- Handler implementation (Task 2)
- Scan-session cache (Task 2)
- Audit / rate limit / notification (Tasks 3–4)
- Phase 3 server entry point (Task 4 docs/integration)


## Summary of Changes

**Files added:**
- `Sources/GargantuaCore/Models/MCP/MCPCleanSchemas.swift` — `MCPCleanInput`, `MCPCleanOutput`, `MCPCleanItemResult`
- `Sources/GargantuaCore/Models/MCP/MCPPhase3Tools.swift` — Phase 3 registry containing only the `clean` descriptor
- `Tests/GargantuaCoreTests/Models/MCP/MCPCleanSchemasTests.swift` — 17 tests

**Files modified:**
- `Sources/GargantuaCore/Models/MCP/MCPToolDescriptor.swift` — added `MCPToolName.clean`; updated doc comments to reference Phase 3
- `Tests/GargantuaCoreTests/Services/MCP/MCPRequestDispatcherTests.swift` — fixed the `tools/list` assertion to compare against `MCPPhase2Tools.all` rather than `MCPToolName.allCases` (which now includes `.clean`)

**Key decisions:**
- `MCPCleanInput.method` is a plain `String` matching the `MCPScanInput.profile` idiom. The JSON schema advertises `["trash", "delete"]`, but decode does not validate — the handler must reject unknown values.
- `MCPCleanInput.confirm` is enforced at decode to be present AND `true` (stricter than `MCPScanInput.dry_run` which defaults missing to `true`). Destructive-path default is more defensive.
- Outcome strings (`"moved" | "skipped" | "failed"`) are stringly-typed on `MCPCleanItemResult`, matching `MCPScanItem.safety`.
- Phase 2 and Phase 3 registries live in physically separate files; `MCPPhase2Tools.all` is untouched and Phase 2 test invariants remain intact.
- The `line_length` violation on the long tool description was resolved by string concatenation rather than a `swiftlint:disable` pragma.

**Notes for Task 2 (`gargantua-53q1` — handler):**
- `CleanupEngine.CleanupItemResult` is two-state (`succeeded: Bool`); wire format is three-state. `"skipped"` is a NEW semantic for items rejected by safety rules before `CleanupEngine` ever sees them — add the mapping in the handler, don't extend `CleanupEngine`.
- Handler must validate `MCPCleanInput.method` against `{"trash", "delete"}` itself.
- Handler must hop to `@MainActor` for `CleanupEngine.clean` via the existing `runBlocking` pattern in `Sources/GargantuaMCP/main.swift:172`.
- Phase 3 dispatcher / opt-in flag does NOT exist yet; Task 2 needs to introduce one (and must not register `clean` into the current Phase 2 dispatcher).
- `MCPPhase2Tools.all` is untouched; do NOT add `clean` to it — the regression test `MCPToolSchemasTests.noCleanToolInPhase2` will catch it.

**Verification:** 873/873 tests pass. Lint clean on the 4 touched files. Ambient lint debt (file length, type body length, inclusive-language in `ScanBucketView.swift`, `ProcessRunner.swift`, etc.) predates this task and is not addressed here — candidate for a separate cleanup bean.
