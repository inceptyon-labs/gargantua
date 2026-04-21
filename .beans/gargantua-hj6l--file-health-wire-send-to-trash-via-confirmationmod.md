---
# gargantua-hj6l
title: 'File Health: wire Send-to-Trash via ConfirmationModalView'
status: completed
type: feature
priority: normal
created_at: 2026-04-20T23:00:20Z
updated_at: 2026-04-21T18:40:24Z
parent: gargantua-qe4a
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

- [x] "Send to Trash" action on every File Health category tab with selected items
- [x] Confirmation tier matches highest-risk selected item
- [x] Items route through `CleanupEngine` → Trash, with audit log entry
- [x] Post-action the tab refreshes to show remaining findings (or rescan prompt)
- [x] Tests cover tier-matching, audit entry shape, and error paths (permission denied, disk full)

## Completed

- Added File Health Send-to-Trash CTA for selected findings and routed it through `ConfirmationModalView` with permanent delete disabled.
- Moved selected items through `CleanupEngine` using `.trash`, wrote File Health audit entries, then showed a cleanup summary that returns to remaining findings.
- Added cleanup-flow tests for selected tier matching, audit entry shape, remaining findings, and permission/disk-full style error surfacing.

## Verification

- `swift test --filter FileHealth`
- `swift test`
- `swiftlint lint --strict -- Sources/GargantuaCore/Services/AuditWriter.swift Sources/GargantuaCore/Views/ConfirmationModalView.swift Sources/GargantuaCore/Views/ConfirmationTier1SingleButton.swift Sources/GargantuaCore/Views/ConfirmationTier2Summary.swift Sources/GargantuaCore/Views/ConfirmationTier3Full.swift Sources/GargantuaCore/Views/FileHealthContainerView.swift Sources/GargantuaCore/Views/FileHealthContainerCleanupFlow.swift Sources/GargantuaCore/Views/FileHealthModels.swift Sources/GargantuaCore/Views/FileHealthSafetyPalette.swift Sources/GargantuaCore/Views/FileHealthView.swift Tests/GargantuaCoreTests/Models/FileHealthSessionStateTests.swift`
- `git diff --check`

## Dependencies

Completed after per-item selection landed.
