# Session Handoff: MCP explain + list_profiles tool handlers

Date: 2026-04-19
Task completed: gargantua-o4ef — "Task: MCP explain + list_profiles tool handlers"
Parent closed: gargantua-2h06 (Feature: MCP Server v1) — all six child Tasks complete
Epic open: gargantua-qe4a (Epic: Phase 2 Intelligence)

## What Was Done

Wired the `explain` and `list_profiles` MCP tool handlers. All five Phase 2 tools (`scan`, `analyze`, `status`, `explain`, `list_profiles`) are now live end-to-end. Feature `gargantua-2h06` is closed with all sibling Tasks complete.

- `MCPExplainToolHandler`: thin envelope shaper over injected `ExplainProvider = (MCPExplainInput) throws -> MCPExplainOutput`. `MCPExplainInput` already enforces path-xor-item_id at decode; the handler forwards to the provider and does the usual `MCPToolError` rethrow + tool-domain `.failure(...)` + `MCPEncoding.clientFacingMessage(for:)` sanitisation. `MCPExplainOutput.lastAccessed: Date?` round-trips as ISO-8601 via `MCPEncoding.encodeAsJSONAny`.
- `MCPExplainToolHandler.defaultFilesystemProvider()`: AI-free shell backed by `FileManager.default` (direct use because `FileManager` is not `Sendable`). Rejects `item_id`, empty paths, and non-absolute paths (tilde included) with `-32602 invalidParams`. Missing/inaccessible paths fall through to a shell response with no `size`/`lastAccessed` (documented as intentional; AI-backed provider will distinguish path-not-found). Size omitted for directories; `lastAccessed` maps to `.modificationDate` (APFS caveat).
- `MCPListProfilesToolHandler`: injected `ProfilesProvider` returning a `ProfilesSnapshot { profiles, active }`. Shapes `CleanupProfile` into `MCPProfileSummary` using `CleanupProfile.id` as the wire `name` so clients can round-trip it through `scan.profile`. `active` is normalised to `""` when the identifier doesn't match any advertised profile (no dangling-id).
- Wired in `Sources/GargantuaMCP/main.swift` using `MCPExplainToolHandler.defaultFilesystemProvider()` and a built-in profiles provider (`CleanupProfile.builtIn` + `active: "light"`).

SC review: Opus self-review Pass 1 fixed directory-size/lastAccessed semantics. Codex Pass 2 flagged 3 WARNINGs + 1 SUGGESTION (no ERRORs); addressed 3 of 4 in-branch:
- W1 (prod provider untested): extracted `defaultFilesystemProvider` into `GargantuaCore` with +9 direct tests.
- W3 (absolute-path contract mismatch): enforced absolute-only + tilde rejection with new test coverage.
- S4 (silent missing-path behavior): kept by design + documented in factory header + test.
- W2 (schema `oneOf` gap): deferred — requires extending `MCPJSONSchema` model.

Baseline 594 → 634 tests (+40). `swift build -Xswiftc -warnings-as-errors` clean. `swiftlint --strict` clean on production files.

## Files Changed

- `Sources/GargantuaCore/Services/MCP/MCPExplainToolHandler.swift` (new, ~150 lines incl. default provider extension)
- `Sources/GargantuaCore/Services/MCP/MCPListProfilesToolHandler.swift` (new, ~110 lines)
- `Sources/GargantuaMCP/main.swift` (modified — handler registration; default explain provider is one factory call)
- `Tests/GargantuaCoreTests/Services/MCP/MCPExplainToolHandlerTests.swift` (new, 18 tests)
- `Tests/GargantuaCoreTests/Services/MCP/MCPExplainDefaultProviderTests.swift` (new, 9 tests)
- `Tests/GargantuaCoreTests/Services/MCP/MCPListProfilesToolHandlerTests.swift` (new, 18 tests)

## Key Decisions (for follow-up Tasks)

- **`MCPProfileSummary.name == CleanupProfile.id`, not display name.** Clients must be able to pass the returned `name` back through `scan.profile` (which expects `"developer"`/`"light"`/`"deep"`, not `"Light Cleanup"`). Display names remain internal to the app.
- **`active` is normalised to `""`, never dangling.** If a caller supplies an active identifier that doesn't match any advertised profile, the wire output has `active: ""` rather than the dangling id. Preserves the invariant that `active` is always resolvable against `profiles[].name` or is explicitly "none".
- **Absolute-only paths for `explain`.** `MCPPhase2Tools.explain` advertises path as "Absolute filesystem path" and the default provider now enforces it. Accepting relative paths would silently resolve against the MCP process CWD and produce surprising metadata depending on launch context.
- **Shell treats missing paths as "unknown metadata," not errors.** The shell's contract is to always render a conservative `"review"` classification for any accepted input. The AI-backed provider that replaces this shell will distinguish "valid path with unknown metadata" from "path not found / permission denied" explicitly.
- **`FileManager` injection abandoned.** `FileManager` is not `Sendable` and the provider closure is `@Sendable`. Tests exercise the provider with real temp files; a mock seam would have required a separate Sendable protocol.

## Next Steps (ordered)

Epic `gargantua-qe4a` (Phase 2 Intelligence) remains open. The next logical tasks depend on the user's priorities — the ready queue has several unblocked Tasks in other Features of the Epic (not under the now-closed gargantua-2h06):

1. **Follow-up on MCP Server v1** (no bean yet — deferred from Codex WARNING #2):
   - Extend `MCPJSONSchema` to support `oneOf`/`anyOf` and close the `explain` input-schema advertising gap.
2. **Feature `gargantua-4nb9`** (Duplicate Finder via fclones) — ready. First Task `gargantua-rp82` is blocked_by `gargantua-i1ii`.
3. **Feature `gargantua-0q30`** (File Health via czkawka_cli) — ready. Tasks include `gargantua-i36a` (blocked) and `gargantua-o8b5` (UI panel).
4. **Task `gargantua-apnw`** (Developer Tools UI) — ready but blocked_by `gargantua-rwpi`.
5. **Feature `gargantua-8igf`** (AI Tier 1 production improvements) — ready at feature level.

Run `beans list --json --ready` at the next session start to see the current ready queue (priorities may have shifted).

## Files to Load Next Session

**If continuing Phase 2 MCP work (schema `oneOf`):**
- `Sources/GargantuaCore/Models/MCP/MCPToolDescriptor.swift` — extend `MCPJSONSchema` struct.
- `Tests/GargantuaCoreTests/Models/MCP/` — existing schema tests (search first, likely in MCPToolDescriptor tests).

**If starting a different Task:**
- Whatever the bean body + parent Feature body reference. Phase 2 MCP is feature-complete and self-contained; no MCP files need re-reading for unrelated Epic work.

## What NOT to Re-Read

- Any `Sources/GargantuaCore/Services/MCP/*` — the entire MCP subsystem is stable and tested. Unless Phase 3 `clean` work starts, these files don't need re-reading.
- `Gargantua-PRD-v5-FINAL.md §7` — fully encoded in code + tests.

## Reference

- PRD §7.3 (tool shapes) and §7.4 (safety guardrails — `scan.dry_run = true` constant).
- Completed bean summary: `.beans/gargantua-o4ef--task-mcp-explain-list-profiles-tool-handlers.md` → "Summary of Changes".
- Feature summary: `.beans/gargantua-2h06--feature-mcp-server-v1.md` → "Summary of Changes".
- SC review fix commit: `fix(mcp): address Codex review findings on explain default provider`.
