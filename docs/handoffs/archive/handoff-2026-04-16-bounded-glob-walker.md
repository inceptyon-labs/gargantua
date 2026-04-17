# Session Handoff: Bounded glob walker in NativeScanAdapter
Date: 2026-04-16
Epic: gargantua-l9dk - Phase 1.5 Native Scanner Cutover
Completed task: gargantua-avik - Bounded glob walker for ** patterns

## What Was Done This Session

1. **Diagnosed root cause** of app hangs on Quick Scan / Deep Clean / Dev Purge — `mo clean` and `mo purge` don't support `--json` despite Phase-1 beans marking that work complete. Only `mo status` and `mo analyze` have real JSON contracts. Filed as gargantua-9hhj with full impact analysis.

2. **Installed** `brew install mole` (by user) and patched `MoleRunner.resolveBinaryPath` to fall back to homebrew paths for dev runs.

3. **Audited Phase-1 state vs PRD** and filed proper beans:
   - Epic gargantua-l9dk (Phase 1.5 Native Scanner Cutover, in-progress, critical)
   - Child features/tasks with explicit per-file wiring checklists

4. **Completed gargantua-lm94**: Wired Quick Scan dashboard button to new `NativeScanAdapter` + `RuleDirectoryResolver`. Replaces `MoCleanAdapter`.

5. **Completed gargantua-lupo** (code-complete, needs live smoke test): Wired Deep Clean view to NativeScanAdapter. Introduced `ScanAdapter` protocol (`Sources/GargantuaCore/Services/ScanAdapter.swift`). Added `NativeScanAdapter.loadDefaults(profile:)` factory. DRY'd rule-loading across Dashboard + Deep Clean. `MainContentView.swift:44-45` now `DeepCleanView(profile: .deep)`.

6. **Completed gargantua-avik**: Built `PathExpander` with bounded walker supporting `~`, `*`, `**` plus depth/entry/time caps. Wired into NativeScanAdapter. SC review caught two high-value bugs:
   - `rule.pattern` (YAML field for `*.dmg`-style file filters) was being ignored — installer rules were offering `~/Downloads` as a single deletable directory. Now enumerates files.
   - Cross-rule path de-duplication — overlapping rules no longer double-count bytes or double-recycle.

## Current State

- Branch: `feature/avik` — 5 commits ahead of main, ready to merge
- Tests: 275/275 passing (265 prior + 10 new PathExpander tests)
- Build: clean
- Lint: clean on touched files (one accepted stylistic `type_body_length` at 255/250)

## Next Steps (ordered)

1. **gargantua-lupo** — live smoke test Deep Clean in the running app (user-driven). Everything else on this bean is coded.

2. **gargantua-guga** — Wire Dev Purge to native scanner. Now unblocked by avik (walker handles `**/node_modules`). Follows the same pattern as Deep Clean (lupo).

3. **gargantua-2xrw** — Delete or gate MoCleanAdapter/MoPurgeAdapter behind ScanAdapter protocol. Blocked on lupo + guga finishing.

4. **gargantua-gf5w** — Bundle `cleanup_rules/` into the shipped .app + decide mo binary strategy.

5. **gargantua-y1zi** — Diagnose why Disk Explorer doesn't work (not blocked by the cutover, separate failure mode).

6. **Follow-up beans surfaced by Codex review of avik** (not yet filed — offer to user):
   - Bounded/cancellable sizing in `DirectorySizeScanner.directorySize` (currently uncapped — a huge `node_modules` can still hang the scan after the bounded expander succeeds)
   - Walker-level exclude pruning so the entry cap doesn't burn inside doomed subtrees
   - Hidden-file handling policy for rules like `.venv`, `.gradle`, `.next`
   - Streaming child enumeration for directories with millions of entries
   - `..` normalization (only matters when community/remote rules land)
   - NativeScanAdapter-level integration tests (PathExpander is well-covered in isolation)

## Files to Load Next Session

- `Gargantua-PRD-v5-FINAL.md` — PRD reference (especially §3.3, §8.2, §10)
- `.beans/gargantua-l9dk--epic-phase-15-native-scanner-cutover.md` — epic with full scope
- `.beans/gargantua-guga--feature-wire-dev-purge-to-native-dev-artifact-scan.md` — next bean to kick
- `Sources/GargantuaCore/Services/NativeScanAdapter.swift` — pattern to mirror when wiring Dev Purge
- `Sources/GargantuaCore/Services/PathExpander.swift` — the walker itself
- `Sources/GargantuaCore/Views/DeepCleanView.swift` — reference for view wiring pattern
- `Sources/Gargantua/MainContentView.swift:57-60` — Dev Purge call site to rewrite

## What NOT to Re-Read

- `.beans/` files already summarized above
- Individual cleanup_rules YAML files (structure is stable)
- MoCleanAdapter / MoPurgeAdapter source (slated for deletion)
