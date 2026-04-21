---
# gargantua-m9y3
title: 'File Health: per-item selection (checkboxes)'
status: completed
type: task
priority: normal
created_at: 2026-04-20T23:00:08Z
updated_at: 2026-04-21T18:13:14Z
parent: gargantua-qe4a
---

`FileHealthView` currently renders czkawka findings grouped by category with no per-item selection — there is no way to pick which findings to act on. Prerequisite for the Send-to-Trash action (see sibling task).

Defer/follow-on work noted in `gargantua-0q30` summary; never got filed as its own bean. Filing now.

## Scope

- Add a `Set<String>` of selected result ids, mirroring `DeepCleanSessionState.selectedResultIDs`, owned by `FileHealthContainerView` or a session-state struct.
- Render a checkbox per row in `FileHealthView`. Use `DenseScanItemRow` or a Health-specific compact row — consistency with Deep Clean is preferred.
- Default selection state: matches Trust Layer defaults (safe-tier pre-selected, review/protected not pre-selected), same policy Deep Clean uses.
- Category tabs should surface per-category total-selected / total-bytes counts in the tab header so users see the impact before switching categories.
- Read-only categories (where czkawka findings are always advisory, e.g., Similar Images for a first pass) can be marked non-selectable if appropriate; otherwise every tier is selectable subject to safety gating.

## Out of scope

- The destructive action itself (Send-to-Trash via `ConfirmationModalView`) — tracked by sibling bean. This task lands the selection UI; the action wires in next.

## Acceptance

- [x] Checkbox per row in every File Health category tab
- [x] Selection state defaults follow Trust Layer safety tiers
- [x] Per-tab selected-count and reclaimable-bytes visible in tab header
- [x] Selection persists across tab switches within a single scan session
- [x] Tests cover default-selection policy and cross-tab selection persistence

## Completed

**Files changed:**
- `Sources/GargantuaCore/Views/FileHealthView.swift`

**Key decisions:**
- Kept the existing session-state model and checkbox row wiring intact; this task already had model tests and per-row selection hooks in place.
- Added selected-byte display to each category chip when that tab has selected findings, so users can see both selected count and selected bytes before switching tabs.
- Preserved design-system tokens: 4px/8px spacing, 4px chip radius, border-only depth, and Trust Layer tint colors for the selection badge.

**Verification:**
- `swift test --filter FileHealth` passed: 19 tests.
- `swift test` passed: 837 tests in 104 suites.
- `swiftlint lint Sources/GargantuaCore/Views/FileHealthView.swift` passed with 0 violations.
- Repository-wide `swiftlint` still fails on pre-existing unrelated violations in MCP, MLX smoke, Smart Uninstaller, Dev Artifact, and other files.

**Notes for next task:**
- The follow-on Send-to-Trash task can consume `FileHealthSessionState.selectedResultIDs` to build the `ConfirmationModalView` payload.
