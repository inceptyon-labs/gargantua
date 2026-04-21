---
# gargantua-l9dk
title: 'Epic: Phase 1.5 Native Scanner Cutover'
status: completed
type: epic
priority: critical
created_at: 2026-04-17T01:05:59Z
updated_at: 2026-04-21T19:06:46Z
---

Replace Mole subprocess scanners with the native YAML-rule-driven scanner. Per PRD §3.3 and §10 Phase 1.5. Prompted by the discovery that mo clean and mo purge do not support --json output, leaving Deep Clean and Dev Purge non-functional despite their beans being marked completed.

## Context

PRD §3.3 calls for a Phase 1.5 "parallel track" that ports Mole's path knowledge into YAML rules + a native Swift scanner, with gradual cutover from the Mole subprocess. The YAML rule porting (gargantua-hi9b) and rule loader (gargantua-5la2) were completed, but the native filesystem scanner and the view wiring were never built — Quick Scan, Deep Clean, and Dev Purge all continued to route through Mole subprocess adapters.

This epic was triggered by the 2026-04-16 discovery (gargantua-9hhj) that `mo clean` and `mo purge` never supported `--json`, so the Phase 1 Mole integration has always been non-functional for those two commands. `mo analyze` and `mo status` remain valid JSON contracts and are not affected.

## Scope

- [x] NativeScanAdapter + RuleDirectoryResolver (gargantua-lm94)
- [x] Deep Clean view rewired (gargantua-lupo)
- [x] Dev Purge view rewired (gargantua-guga)
- [x] Bounded glob walker for `**` patterns (gargantua-avik)
- [x] Bundle cleanup_rules + decide mo strategy for shipped .app (gargantua-gf5w)
- [x] Dead-code cleanup / adapter protocol (gargantua-2xrw)

## Success Criteria
- [x] Quick Scan, Deep Clean, and Dev Purge all produce real results against the YAML rule set without invoking `mo clean`/`mo purge`
- [x] Built `.app` (not just `swift run`) finds rules and scans
- [x] `CleanupEngine` end-to-end flow (scan → confirm → Trash → audit) verified working
- [x] `MoCleanAdapter` and `MoPurgeAdapter` are either deleted or gated behind a protocol with a non-default implementation

## Out of Scope
- MCP server (Phase 2 per PRD §10)
- AI tier integration (Phase 2-3)
- fclones / czkawka adapters (Phase 2)


## Completed Child: gargantua-avik (Bounded glob walker)

**Files:**
- Sources/GargantuaCore/Services/PathExpander.swift (new, bounded filesystem walker)
- Sources/GargantuaCore/Services/NativeScanAdapter.swift (modified — glob support, pattern field support, cross-rule de-dup, display-name disambiguation)
- Tests/GargantuaCoreTests/Services/PathExpanderTests.swift (new, 10 tests)

**Key decisions:**
- `ScanAdapter` protocol introduced so future engines (fclones, native uninstaller) slot in without touching views
- `PathExpander` uses a WalkState class (not struct) to sidestep Swift exclusivity violations on overlapping recursive inout accesses
- `RuleDirectoryResolver` stays in NativeScanAdapter.swift — it's the adapter's concern
- `rule.pattern` YAML field is honored — installer rules (Downloads + *.dmg) now enumerate matching files instead of offering the whole directory

**Notes for sibling tasks:**
- `NativeScanAdapter.loadDefaults(profile:)` is the one-line factory to use from view code — takes care of rule loading and resolver logic
- `PathExpander.defaultScanRoots()` returns sensible defaults for dev-artifact patterns; callers can override via `NativeScanAdapter.init(..., scanRoots:)`
- Deduplication is by path in `scan()`, so overlapping rules are safe
- `gargantua-guga` (Dev Purge wiring) can proceed — the walker handles `**/node_modules`-style rules now

## Completion (2026-04-21)

All child beans under the Phase 1.5 Native Scanner Cutover are complete:

- `gargantua-lm94`: Quick Scan uses `NativeScanAdapter` with the `.light` profile.
- `gargantua-lupo`: Deep Clean uses `NativeScanAdapter.loadDefaults(profile:)`, receives the active cleanup profile from app settings, and preserves the existing confirmation / cleanup flow.
- `gargantua-guga`: Dev Purge uses `NativeScanAdapter` with `.devPurge` and persisted scan roots.
- `gargantua-avik`: bounded glob walking resolves `**` and `*` rule paths with caps and warning propagation.
- `gargantua-gf5w`: `cleanup_rules` ship as a GargantuaCore SPM resource, `RuleDirectoryResolver` resolves through `Bundle.module`, and the app no longer depends on `mo`.
- `gargantua-2xrw`: `MoCleanAdapter` / `MoPurgeAdapter` and their tests are deleted; `NativeScanAdapter` is the remaining scan adapter path for these views.
- `gargantua-i6ev`: live app smoke completed from `swift run Gargantua`; Deep Clean, Dev Purge, cleanup to Trash, audit writing, System Status, and Disk Explorer were verified.

Closeout verification on 2026-04-21:

- `swift test` passed: 848 tests across 107 suites.
- `dist/Gargantua.app/Contents/Resources/Gargantua_GargantuaCore.bundle/cleanup_rules` exists, and the release resource bundle contains the expected browser, developer, and system YAML rule files.
- No source references remain for `MoCleanAdapter`, `MoPurgeAdapter`, `MoleRunner`, `MoAnalyzeAdapter`, or `MoStatusAdapter`.
