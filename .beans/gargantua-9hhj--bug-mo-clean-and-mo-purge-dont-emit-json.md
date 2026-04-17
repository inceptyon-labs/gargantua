---
# gargantua-9hhj
title: 'Bug: mo clean and mo purge don''t emit JSON'
status: completed
type: bug
priority: critical
created_at: 2026-04-17T01:06:04Z
updated_at: 2026-04-17T15:39:31Z
parent: gargantua-l9dk
---

Phase 1 Mole integration assumed 'mo clean --json' and 'mo purge --json' produce structured output. They do not — these are TUI-only commands that silently ignore --json. MoCleanAdapter and MoPurgeAdapter therefore hang or produce unparseable ANSI text.

## Investigation (2026-04-16)

Verified against mole 1.34.0 (`brew install mole`):

| Command | `--json` supported? |
|---|---|
| `mo status` | Yes — structured JSON |
| `mo analyze` | Yes — structured JSON |
| `mo clean` | **No** — TUI only, flag silently ignored |
| `mo purge` | **No** — TUI only |

Symptom: `swift run Gargantua` → Quick/Deep/Dev Purge buttons hang at "Scanning". Subprocess writes ANSI text to the captured stdout pipe; on a terminal-launched app it also emits a sudo prompt that the GUI cannot respond to, compounding the hang.

## Impact on existing beans

These "completed" beans shipped implementations that cannot produce results:
- gargantua-jj6r (Feature: Mole Command Adapters) — mo clean/purge paths non-functional
- gargantua-yyny (Task: Implement mo clean and mo purge command adapters) — passes unsupported flags
- gargantua-obof (Task: Parse Mole JSON output into ScanResult models) — nothing to parse
- gargantua-q0og (Epic: Mole Integration) — success criteria "all four commands produce typed ScanResult output" not met for clean/purge

These should not be retroactively edited; the cutover epic (gargantua-l9dk) supersedes them.

## Resolution

Cutover to native scanner for clean + purge. `mo analyze` and `mo status` continue to use their real JSON contracts.

## Fix Tasks
- [x] Deep Clean view wired to NativeScanAdapter (gargantua-lupo)
- [x] Dev Purge view wired to native dev-artifact walker (gargantua-guga)
- [x] MoCleanAdapter + MoPurgeAdapter deleted (callsites already gone via lupo + guga)

## Summary of Changes

Deleted `Sources/GargantuaCore/Services/MoCleanAdapter.swift`, `MoPurgeAdapter.swift`, and their test files. Scrubbed a stale `MoCleanAdapter.scan`-shape comment from `NativeScanAdapter.swift`. Production callsites were already removed by gargantua-lupo (Deep Clean) and gargantua-guga (Dev Purge), so deletion only touched the adapters + tests. `swift build` clean; 281 tests across 40 suites pass. This also closes gargantua-2xrw (same work).
