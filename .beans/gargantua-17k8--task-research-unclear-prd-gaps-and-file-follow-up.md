---
# gargantua-17k8
title: 'Task: Research unclear PRD gaps and file follow-up beans'
status: completed
type: task
priority: normal
created_at: 2026-04-23T20:55:27Z
updated_at: 2026-04-23T23:01:48Z
---

Investigate PRD items whose implementation status couldn't be determined from a surface scan. For each, either confirm it's done (mark this todo item ✅ and cite the code) or file a new bean and link it here.

## Items to investigate

- [x] **Native SwiftUI treemap view (PRD §5.5)** — Disk Explorer exists, but it renders a sorted expandable list with size bars, not weighted treemap rectangles. Follow-up: `gargantua-c89y`.
- [x] **Whitelists settings pane (PRD §5.2)** — Whitelist CRUD exists inside `RuleViewerView`, but `SettingsView` does not expose a dedicated Whitelists pane. Follow-up: `gargantua-5fds`.
- [x] **czkawka broken symlinks feature (PRD §4.2)** — Confirmed done end-to-end: scan category, parser, safety mapping, File Health UI, confirmation, Trash cleanup, and tests exist. No follow-up needed.
- [x] **Finder Automation TCC fallback (PRD §9)** — Onboarding mentions Finder automation, but runtime cleanup uses `NSWorkspace.recycle` / `FileManager.trashItem`; no Finder Automation path or fallback selector exists. Follow-up: `gargantua-z4wa`.
- [x] **Community rules repo (PRD §14)** — Rule docs are in-tree, `docs/rules/status.md` frames a separate repo as future work, and GitHub search found no relevant public `gargantua-rules` repo. Follow-up: `gargantua-071c`.

## Todo

- [x] Complete each investigation above
- [x] For each gap confirmed, create a follow-up bean and link ID here
- [x] Post summary of findings in this bean's summary section before marking complete

## Summary of Findings

### Native SwiftUI treemap view

Status: gap confirmed.

Evidence:
- `Sources/GargantuaCore/Views/DiskExplorerView.swift:3` describes the shipped view as a sorted expandable list with size bars.
- `Sources/GargantuaCore/Views/DiskExplorerView.swift:98` renders a `ScrollView` / `LazyVStack` row list.
- `Sources/GargantuaCore/Views/DiskExplorerView.swift:321` renders horizontal size bars, not weighted rectangles.
- Completed feature `gargantua-9xm6` explicitly scoped Disk Explorer to sorted list / size bars and put treemap out of scope.

Filed follow-up: `gargantua-c89y` — Feature: Native SwiftUI Disk Explorer treemap view.

### Whitelists settings pane

Status: gap confirmed.

Evidence:
- `Sources/Gargantua/MainContentView.swift:101` routes the standalone `rules` sidebar item to `RuleViewerView`.
- `Sources/GargantuaCore/Views/RuleViewerView.swift:265` wires whitelist management inside the rule detail pane.
- `Sources/GargantuaCore/Views/RuleViewerView.swift:404` defines the add/remove whitelist UI.
- `Sources/GargantuaCore/Views/SettingsView.swift:36` renders AI Model, scan roots, and General sections only; there is no dedicated Whitelists pane in Settings.

Filed follow-up: `gargantua-5fds` — Feature: Dedicated Settings Whitelists pane.

### czkawka broken symlinks feature

Status: done; no follow-up needed.

Evidence:
- `Sources/GargantuaCore/Services/CzkawkaOutputParser.swift:10` includes `brokenSymlinks`.
- `Sources/GargantuaCore/Services/CzkawkaOutputParser.swift:22` maps it to the `symlinks` subcommand and `:45` maps results to `broken_symlinks`.
- `Sources/GargantuaCore/Services/CzkawkaAdapter.swift:52` classifies broken symlink findings as `.safe` with 95 confidence.
- `Sources/GargantuaCore/Views/FileHealthContainerView.swift:99` renders scan output through `FileHealthView`, and `:309` builds the default engine from `CzkawkaAdapter.autoDetect`.
- `Sources/GargantuaCore/Views/FileHealthContainerCleanupFlow.swift:69` routes selected File Health items through Trash cleanup.
- Tests cover parsing, adapter invocation, safety defaults, grouping, and selected File Health cleanup state.

### Finder Automation TCC fallback

Status: gap confirmed.

Evidence:
- `Sources/GargantuaCore/Views/PermissionRequestFlowView.swift:100` implements an Automation screen and `:110` says Gargantua uses Finder automation.
- `Sources/GargantuaCore/Services/CleanupEngine.swift:139` documents direct `NSWorkspace` recycling and `:143` calls `NSWorkspace.shared.recycle`.
- `Sources/GargantuaPrivilegedHelper/main.swift:49` uses `FileManager.default.trashItem` for privileged helper moves.
- Repo search found no AppleEvent, osascript, or Finder automation cleanup path.

Filed follow-up: `gargantua-z4wa` — Task: Finder Automation trash path with direct API fallback.

### Community rules repo

Status: gap confirmed.

Evidence:
- `README.md:12` and `CONTRIBUTING.md:9` point contributors to in-tree rule docs and resource directories.
- `docs/rules/status.md:58` says a dedicated `gargantua-rules` repo is a future next documentation move.
- `gh search repos gargantua-rules --limit 20` returned `[]` on 2026-04-23; web search also found no relevant GitHub repository.

Filed follow-up: `gargantua-071c` — Task: Create public gargantua-rules repository and link it.

## Completed

**Files changed:**
- `.beans/gargantua-17k8--task-research-unclear-prd-gaps-and-file-follow-up.md`
- `.beans/gargantua-c89y--feature-native-swiftui-disk-explorer-treemap-view.md`
- `.beans/gargantua-5fds--feature-dedicated-settings-whitelists-pane.md`
- `.beans/gargantua-z4wa--task-finder-automation-trash-path-with-direct-api.md`
- `.beans/gargantua-071c--task-create-public-gargantua-rules-repository-and.md`

**Key decisions:**
- Treat existing broken-symlink support as complete because it has scan, UI, cleanup, safety, and test coverage.
- File new follow-ups only where the current implementation diverges from the specific PRD wording.

**Notes for next task:**
- `gargantua-vdeg` remains the Phase 3 MCP SSE feature called out in the archived handoff, but it is blocked by `gargantua-n4jn`.
- `beans list --ready -t task` selected this research task first; after closure, re-run ready selection for the next actionable leaf task.
