---
# gargantua-hj6l
title: 'File Health: wire Send-to-Trash via ConfirmationModalView'
status: todo
type: feature
priority: normal
created_at: 2026-04-20T23:00:20Z
updated_at: 2026-04-20T23:00:27Z
parent: gargantua-qe4a
blocked_by:
    - gargantua-m9y3
---

File Health tabs are currently read-only by design (see `FileHealthContainerView.swift:18` — "Destructive operations are intentionally not wired here"). The `gargantua-0q30` feature summary lists the Send-to-Trash action as deferred follow-on work that never got filed. Filing now.

## Scope

- Once per-item selection lands (sibling task), add a "Send to Trash" CTA in File Health's action bar (same location Deep Clean uses `onClean`).
- Route through `ConfirmationModalView` using the same tiered-confirmation contract Deep Clean + Duplicate Finder use:
  - Safe-only selection → single-button confirm
  - Mixed with review → summary dialog
  - Protected items → full modal with per-item acknowledgment
- Execution via `CleanupEngine` (Trash-first, with the same undo/retention guarantees as Deep Clean — see `gargantua-hjrd`).
- Audit log entry per operation (`AuditWriter`).

## Out of scope

- Permanent delete. Trash-first only; users recover via Finder's Trash.
- czkawka "delete in place" mode — czkawka_cli has its own delete flags but we intentionally don't use them (Trust Layer + our confirmation tiers own the action).

## Acceptance

- [ ] "Send to Trash" action on every File Health category tab with selected items
- [ ] Confirmation tier matches highest-risk selected item
- [ ] Items route through `CleanupEngine` → Trash, with audit log entry
- [ ] Post-action the tab refreshes to show remaining findings (or rescan prompt)
- [ ] Tests cover tier-matching, audit entry shape, and error paths (permission denied, disk full)

## Dependencies

Blocked by per-item selection task (File Health needs checkboxes before it can have an action).
