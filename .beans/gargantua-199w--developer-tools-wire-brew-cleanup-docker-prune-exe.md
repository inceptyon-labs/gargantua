---
# gargantua-199w
title: 'Developer Tools: wire brew cleanup / docker prune execution behind ConfirmationModalView'
status: todo
type: feature
priority: normal
created_at: 2026-04-20T23:20:12Z
updated_at: 2026-04-20T23:20:12Z
parent: gargantua-qe4a
---

`DeveloperToolsView` is currently read-only by design. The panel surfaces dry-run previews of `brew cleanup` and `docker system df` output but offers no way to actually run them. From `DeveloperToolsView.swift:16-18`:

> "Destructive operations are intentionally not exposed — Phase 3 will route execution through the Trust Layer / `ConfirmationModalView`. The visible command preview lets the user see exactly what would run."

The completed parent feature `gargantua-7hdn` explicitly deferred this execution path to Phase 3; this bean files it so the work is trackable.

## Context

Developer Tools is complementary to Dev Artifact Purge:
- **Dev Artifact Purge** (`DevArtifactScanView`): filesystem scan → `NativeScanAdapter` → Trash via `CleanupEngine`. Good for wiping whole directories (Homebrew caches, Docker VM disk) as blob reclaim.
- **Developer Tools** (this bean's subject): shellout to the tool's own cleanup subcommand. Good for *tool-aware* reclaim — `brew cleanup` prunes old formula versions with knowledge of the dependency graph; `docker image prune` / `docker container prune` / `docker volume prune` use Docker's own index of dangling/unused resources that filesystem rules can't safely identify.

Both should exist. Neither subsumes the other.

## Scope

1. **Executable command set per tool.** Define a small enum of tool-specific cleanup operations (not free-form shellout):
   - Homebrew: `brew cleanup` (old versions), `brew cleanup --prune=all` (aggressive), optionally `brew autoremove`.
   - Docker: `docker image prune`, `docker container prune`, `docker volume prune`, `docker builder prune`, `docker system prune` (composite).
   Each operation carries its `SafetyLevel` (mostly `.review` — the previews are hints, not guarantees of reclaim) and a human-readable label.

2. **Preview → Confirm → Execute flow.** Reuse the existing dry-run adapter to surface "this would reclaim ~X MB", then route through `ConfirmationModalView` with a tier matching the operation's safety level (most are `.summaryDialog`; `system prune` flavors are `.fullModal`). Execute via a `DeveloperToolExecutionAdapter` that runs the command through `DefaultProcessRunner` with the same audit logging `CleanupEngine` uses.

3. **Post-execution state.** After a successful run, re-fetch the dry-run preview to show updated reclaimable numbers. On failure, surface stderr (already the pattern for Dev Artifact Purge errors) and a retry action.

4. **No filesystem overlap.** This bean only wires tool-native commands. Directories that Dev Artifact Purge already handles (e.g., `~/Library/Caches/Homebrew`) stay with Dev Artifact Purge — the split of responsibilities is documented in the view headers.

## Out of scope

- Composite workflows ("run brew cleanup AND docker prune in one click"). Each operation stays discrete so audit log entries are per-command.
- Automatic scheduling of cleanups. Manual-only; scheduling is a separate concern.
- Any tool besides Homebrew and Docker until availability-gated support for more tools lands (a different feature bean).

## Acceptance

- [ ] `DeveloperToolExecutionAdapter` runs the defined commands through `DefaultProcessRunner` with timeout, audit entry, and stderr capture
- [ ] `DeveloperToolsView` renders a "Run" button per operation, gated on the tool being installed and the operation being applicable
- [ ] Clicking "Run" opens `ConfirmationModalView` at the tier matching the operation's `SafetyLevel`
- [ ] On confirm, command runs; on complete, UI refreshes dry-run preview and shows the delta
- [ ] Audit log entry written per operation via `AuditWriter`
- [ ] Failure path surfaces stderr and offers retry
- [ ] Tests cover: adapter command construction, tier-matching, post-run preview refresh, audit entry shape, failure path
