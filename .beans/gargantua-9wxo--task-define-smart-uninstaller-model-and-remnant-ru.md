---
# gargantua-9wxo
title: 'Task: Define Smart Uninstaller model and remnant rule schema'
status: completed
type: task
priority: high
created_at: 2026-04-17T18:07:38Z
updated_at: 2026-04-17T21:45:44Z
parent: gargantua-j8a1
---

Design app/remnant models, YAML rule schema for uninstall remnants, and safety mapping before implementing cleanup execution.

## Summary of Changes

Introduced the data-model foundation for the Smart Uninstaller (Phase 2).

**New models** (Sources/GargantuaCore/Models/Uninstaller/):
- `AppInfo` — NSWorkspace / Launch Services metadata capture (bundleID, version, signature, running state, size).
- `RemnantCategory` — 13-case enum of macOS remnant families with a `defaultSafety` mapping (safe/review/protected).
- `RemnantRule` / `RemnantRuleFile` / `AppScope` — YAML rule schema with placeholder path templates (`{bundleID}`, `{appName}`, `{teamID}`) and allow/deny scoping.
- `RemnantItem` — discovered remnant analogous to `ScanResult`, keyed to an owning `AppInfo`.
- `UninstallPlan` — per-app aggregate with `totalBytes`, `remnantsByCategory`, `actionableItems`.

**Parser + resources**:
- `RemnantRuleParser` — Yams-based parser under a distinct `remnant_rules` top-level key.
- `Resources/uninstall_rules/default_remnants.yaml` — 12 generic remnant rules (caches, preferences, containers, launch agents/daemons, logs, WebKit storage, helpers).
- `Package.swift` — copies `uninstall_rules` into the bundle.

**Tests** (42 new): Codable round-trips, category defaults, scope matching, parser happy/error paths, bundled-YAML sanity check. Suite: 335/335 passing.



Merged in b6069c3.
