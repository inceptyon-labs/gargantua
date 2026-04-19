---
# gargantua-o4ef
title: 'Task: MCP explain + list_profiles tool handlers'
status: completed
type: task
priority: normal
created_at: 2026-04-18T22:18:43Z
updated_at: 2026-04-19T01:53:42Z
parent: gargantua-2h06
blocked_by:
    - gargantua-xc7m
---

Implement explain handler (path or item_id mutual exclusion already enforced in input type) returning an AI-free explanation shell that can be backed by AIInferenceEngine later. Implement list_profiles handler returning available scan profiles. Reference: MCPToolSchemas.swift MCPExplainInput/Output, MCPListProfilesOutput.


## Summary of Changes

Wired the `explain` and `list_profiles` MCP tool handlers. All five Phase 2 tools (`scan`, `analyze`, `status`, `explain`, `list_profiles`) are now live end-to-end. Feature `gargantua-2h06` should close once this bean is marked completed.

- `MCPExplainToolHandler`: thin envelope shaper over injected `ExplainProvider = (MCPExplainInput) throws -> MCPExplainOutput`. `MCPExplainInput` already enforces path-xor-item_id at decode; the handler forwards to the provider and does the usual `MCPToolError` rethrow + tool-domain `.failure(...)` + `MCPEncoding.clientFacingMessage(for:)` sanitisation. `MCPExplainOutput.lastAccessed: Date?` round-trips as ISO-8601 via the shared `MCPEncoding.encodeAsJSONAny` helper.
- `MCPExplainToolHandler.defaultFilesystemProvider()`: AI-free shell backed by `FileManager`. Rejects `item_id`, empty paths, and non-absolute paths (tilde included) with `-32602 invalidParams`. Missing/inaccessible paths fall through to a shell response with no `size`/`lastAccessed` — documented in the factory header as intentional; the AI-backed provider that replaces this shell will distinguish path-not-found. Size is omitted for directories (`.size` is inode size, not recursive total). `lastAccessed` maps to `.modificationDate` since APFS often disables true content-access time.
- `MCPListProfilesToolHandler`: injected `ProfilesProvider` returning a `ProfilesSnapshot { profiles, active }`. Shapes `CleanupProfile` into `MCPProfileSummary` using `CleanupProfile.id` as the wire `name` so clients can round-trip it back through `scan.profile`. `active` is normalised to `""` when the identifier doesn't match any advertised profile (prevents dangling-id selection).
- Wired both handlers in `Sources/GargantuaMCP/main.swift`. Default profiles provider: `CleanupProfile.builtIn` + `active: "light"` (same safest-built-in default `scan` uses).

SC review: Opus self-review Pass 1 fixed directory-size/lastAccessed semantics. Codex Pass 2 flagged prod-provider test gap (fixed: extracted `defaultFilesystemProvider` into `GargantuaCore` with +9 direct tests), relative-path contract mismatch (fixed: absolute-only + tilde rejection), and silent missing-path behavior (kept by design + documented). Schema `oneOf` for `explain.path`/`item_id` (WARNING #2) deferred — requires extending `MCPJSONSchema` model, out of scope.

Baseline 594 → 634 tests (+40). `swift build -Xswiftc -warnings-as-errors` clean.

## Files Changed

- `Sources/GargantuaCore/Services/MCP/MCPExplainToolHandler.swift` (new, ~150 lines incl. default provider extension)
- `Sources/GargantuaCore/Services/MCP/MCPListProfilesToolHandler.swift` (new, ~110 lines)
- `Sources/GargantuaMCP/main.swift` (modified — explain + list_profiles registration; default explain provider now one factory call)
- `Tests/GargantuaCoreTests/Services/MCP/MCPExplainToolHandlerTests.swift` (new, 18 tests)
- `Tests/GargantuaCoreTests/Services/MCP/MCPExplainDefaultProviderTests.swift` (new, 9 tests)
- `Tests/GargantuaCoreTests/Services/MCP/MCPListProfilesToolHandlerTests.swift` (new, 18 tests)

## Notes for Follow-Ups

- **Schema `oneOf` for `explain`** (Codex WARNING #2): `tools/list` currently advertises `explain.path` and `explain.item_id` both optional with `required: []`. Runtime decode rejects neither-both but schema-driven clients can generate invalid calls. Extending `MCPJSONSchema` to support `oneOf`/`anyOf` (plus a schema test) would close the gap.
- **AI-backed explain provider**: swap `MCPExplainToolHandler.defaultFilesystemProvider()` for an `AIInferenceEngine`-backed provider at the factory call in `main.swift`. Handler and tests need no changes.
- **Persisted profiles bridge**: the default `ProfilesProvider` is hardcoded to `CleanupProfile.builtIn + "light"`. Wiring the app's real persisted profiles + active-profile selection (and dropping `'custom'` rejection in the scan handler) lands at that provider boundary.
- **scan-backed `top_consumers`**: still empty in the `analyze` output; sibling follow-up on top of `gargantua-2h06`.
